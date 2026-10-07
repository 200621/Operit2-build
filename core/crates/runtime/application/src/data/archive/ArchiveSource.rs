use std::io::{self, Read, Seek, SeekFrom};
use std::sync::Arc;

const ARCHIVE_SOURCE_READ_CHUNK_BYTES: usize = 64 * 1024;
const ARCHIVE_SOURCE_HEADER_BLOCK_BYTES: usize = 4 * 1024;
const ARCHIVE_SOURCE_CACHED_BLOCK_COUNT: usize = 2;

/// Reads bounded byte ranges from one immutable archive object.
pub(crate) trait ArchiveSource: Send + Sync {
    /// Returns the persisted byte length of this immutable archive.
    fn len(&self) -> Result<u64, String>;

    /// Reads the complete requested range, bounded by the immutable archive length.
    fn readAt(&self, offset: u64, length: usize) -> Result<Vec<u8>, String>;
}

/// Retains one immutable range used by ZIP header scans or entry payload reads.
#[derive(Clone)]
struct ArchiveSourceBlock {
    offset: u64,
    bytes: Arc<[u8]>,
}

/// Adapts one range-readable archive source to synchronous ZIP reader contracts.
#[derive(Clone)]
pub(crate) struct ArchiveSourceReader {
    source: Arc<dyn ArchiveSource>,
    position: u64,
    cachedBlocks: Vec<ArchiveSourceBlock>,
}

impl ArchiveSourceReader {
    /// Creates a ZIP-compatible reader over the supplied immutable archive source.
    pub(crate) fn new(source: Arc<dyn ArchiveSource>) -> Self {
        Self {
            source,
            position: 0,
            cachedBlocks: Vec::with_capacity(ARCHIVE_SOURCE_CACHED_BLOCK_COUNT),
        }
    }

    /// Converts one archive-source error into an I/O error for ZIP consumers.
    fn sourceError(error: String) -> io::Error {
        io::Error::new(io::ErrorKind::Other, error)
    }
}

impl Read for ArchiveSourceReader {
    /// Retains index and local-header blocks across interleaved ZIP seeks with bounded read-ahead.
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let cachedIndex = self.cachedBlocks.iter().position(|block| {
            self.position >= block.offset && self.position - block.offset < block.bytes.len() as u64
        });
        if let Some(index) = cachedIndex {
            self.cachedBlocks.swap(0, index);
        } else {
            let sourceLength = self.source.len().map_err(Self::sourceError)?;
            if self.position == sourceLength {
                return Ok(0);
            }
            let blockLength = if buffer.len() <= ARCHIVE_SOURCE_HEADER_BLOCK_BYTES {
                ARCHIVE_SOURCE_HEADER_BLOCK_BYTES
            } else {
                ARCHIVE_SOURCE_READ_CHUNK_BYTES
            } as u64;
            let cachedOffset = self.position - self.position % blockLength;
            let requestedLength = (sourceLength - cachedOffset).min(blockLength) as usize;
            let bytes = self
                .source
                .readAt(cachedOffset, requestedLength)
                .map_err(Self::sourceError)?;
            if bytes.len() != requestedLength {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "archive source returned an incomplete or oversized range",
                ));
            }
            self.cachedBlocks
                .truncate(ARCHIVE_SOURCE_CACHED_BLOCK_COUNT - 1);
            self.cachedBlocks.insert(
                0,
                ArchiveSourceBlock {
                    offset: cachedOffset,
                    bytes: bytes.into(),
                },
            );
        }
        let block = &self.cachedBlocks[0];
        let cachedPosition = (self.position - block.offset) as usize;
        let count = buffer.len().min(block.bytes.len() - cachedPosition);
        buffer[..count].copy_from_slice(&block.bytes[cachedPosition..cachedPosition + count]);
        self.position += count as u64;
        Ok(count)
    }
}

impl Seek for ArchiveSourceReader {
    /// Repositions the ZIP reader within the immutable archive source.
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let sourceLength = self.source.len().map_err(Self::sourceError)?;
        let next = match position {
            SeekFrom::Start(offset) => i128::from(offset),
            SeekFrom::Current(offset) => i128::from(self.position) + i128::from(offset),
            SeekFrom::End(offset) => i128::from(sourceLength) + i128::from(offset),
        };
        if next < 0 || next > i128::from(sourceLength) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "archive seek is outside the source",
            ));
        }
        self.position = u64::try_from(next).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "archive seek does not fit u64")
        })?;
        Ok(self.position)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::io::Cursor;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Tracks host range reads over one immutable in-memory archive.
    struct CountingArchiveSource {
        bytes: Vec<u8>,
        reads: AtomicUsize,
        readBytes: AtomicUsize,
    }

    impl CountingArchiveSource {
        /// Creates a counted source containing the supplied archive bytes.
        fn new(bytes: Vec<u8>) -> Arc<Self> {
            Arc::new(Self {
                bytes,
                reads: AtomicUsize::new(0),
                readBytes: AtomicUsize::new(0),
            })
        }
    }

    impl ArchiveSource for CountingArchiveSource {
        /// Returns the exact length of the test archive.
        fn len(&self) -> Result<u64, String> {
            Ok(self.bytes.len() as u64)
        }

        /// Returns the requested bytes and counts each host-boundary read.
        fn readAt(&self, offset: u64, length: usize) -> Result<Vec<u8>, String> {
            assert!(length <= ARCHIVE_SOURCE_READ_CHUNK_BYTES);
            self.reads.fetch_add(1, Ordering::Relaxed);
            self.readBytes.fetch_add(length, Ordering::Relaxed);
            let start = offset as usize;
            Ok(self.bytes[start..(start + length).min(self.bytes.len())].to_vec())
        }
    }

    /// Reads byte-sized ZIP fields using one host read per source block.
    #[test]
    fn tiny_reads_share_bounded_host_blocks() {
        let bytes = (0..ARCHIVE_SOURCE_READ_CHUNK_BYTES + 17)
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        let source = CountingArchiveSource::new(bytes.clone());
        let mut reader = ArchiveSourceReader::new(source.clone());
        for expected in bytes {
            let mut byte = [0];
            reader.read_exact(&mut byte).unwrap();
            assert_eq!(byte[0], expected);
        }
        assert_eq!(reader.read(&mut [0]).unwrap(), 0);
        assert_eq!(
            source.reads.load(Ordering::Relaxed),
            (ARCHIVE_SOURCE_READ_CHUNK_BYTES + 17).div_ceil(ARCHIVE_SOURCE_HEADER_BLOCK_BYTES),
        );
    }

    /// Retains cached bytes when ZIP seeks backward or forward inside a block.
    #[test]
    fn seeks_and_clones_reuse_cached_bytes() {
        let source = CountingArchiveSource::new((0..200).collect());
        let mut reader = ArchiveSourceReader::new(source.clone());
        reader.read_exact(&mut [0; 4]).unwrap();
        reader.seek(SeekFrom::Start(100)).unwrap();
        let mut cloned = reader.clone();
        let mut bytes = [0; 3];
        cloned.read_exact(&mut bytes).unwrap();
        assert_eq!(bytes, [100, 101, 102]);
        reader.seek(SeekFrom::Current(-98)).unwrap();
        reader.read_exact(&mut bytes).unwrap();
        assert_eq!(bytes, [2, 3, 4]);
        reader.seek(SeekFrom::End(-2)).unwrap();
        assert_eq!(reader.read(&mut bytes).unwrap(), 2);
        assert_eq!(&bytes[..2], &[198, 199]);
        assert_eq!(source.reads.load(Ordering::Relaxed), 1);
        assert!(reader.seek(SeekFrom::End(1)).is_err());
        assert!(reader.seek(SeekFrom::Start(201)).is_err());
    }

    /// Keeps both ZIP index and local header ranges cached during repeated cross-region seeks.
    #[test]
    fn interleaved_index_and_header_reads_retain_both_blocks() {
        let offset = ARCHIVE_SOURCE_READ_CHUNK_BYTES * 2;
        let source = CountingArchiveSource::new(vec![42; offset + 32]);
        let mut reader = ArchiveSourceReader::new(source.clone());
        for _ in 0..100 {
            for position in [0, offset] {
                reader.seek(SeekFrom::Start(position as u64)).unwrap();
                let mut bytes = [0; 16];
                reader.read_exact(&mut bytes).unwrap();
                assert_eq!(bytes, [42; 16]);
            }
        }
        assert_eq!(source.reads.load(Ordering::Relaxed), 2);
        assert_eq!(reader.cachedBlocks.len(), ARCHIVE_SOURCE_CACHED_BLOCK_COUNT);
    }

    /// Avoids reading full payload-sized blocks when only distant ZIP headers are scanned.
    #[test]
    fn distant_header_reads_use_small_bounded_blocks() {
        let spacing = ARCHIVE_SOURCE_READ_CHUNK_BYTES * 8;
        let source = CountingArchiveSource::new(vec![42; 10 * spacing]);
        let mut reader = ArchiveSourceReader::new(source.clone());
        for index in 0..10 {
            reader
                .seek(SeekFrom::Start((index * spacing) as u64))
                .unwrap();
            reader.read_exact(&mut [0; 32]).unwrap();
        }
        assert_eq!(source.reads.load(Ordering::Relaxed), 10);
        assert_eq!(
            source.readBytes.load(Ordering::Relaxed),
            10 * ARCHIVE_SOURCE_HEADER_BLOCK_BYTES
        );
    }

    /// Avoids host reads for empty input buffers and end-of-archive reads.
    #[test]
    fn empty_reads_do_not_call_the_host() {
        let source = CountingArchiveSource::new(Vec::new());
        let mut reader = ArchiveSourceReader::new(source.clone());
        assert_eq!(reader.read(&mut []).unwrap(), 0);
        assert_eq!(reader.read(&mut [0; 8]).unwrap(), 0);
        assert_eq!(source.reads.load(Ordering::Relaxed), 0);
    }

    /// Rejects incomplete sealed source blocks instead of treating them as archive EOF.
    #[test]
    fn incomplete_source_ranges_are_errors() {
        /// Returns fewer bytes than the immutable source length declares.
        struct IncompleteArchiveSource;

        impl ArchiveSource for IncompleteArchiveSource {
            /// Declares one complete source block.
            fn len(&self) -> Result<u64, String> {
                Ok(ARCHIVE_SOURCE_READ_CHUNK_BYTES as u64)
            }

            /// Deliberately violates the sealed range-read contract.
            fn readAt(&self, _offset: u64, _length: usize) -> Result<Vec<u8>, String> {
                Ok(vec![0; 4])
            }
        }

        let mut reader = ArchiveSourceReader::new(Arc::new(IncompleteArchiveSource));
        let error = reader.read(&mut [0; 8]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    /// Opens and extracts a many-entry ZIP without one host call per ZIP header field.
    #[test]
    fn zip_headers_and_cloned_directory_use_bounded_host_reads() {
        use std::io::Write;

        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        for index in 0..1000 {
            writer
                .start_file(format!("payload/files/{index:04}.txt"), options)
                .unwrap();
            writer.write_all(b"test payload").unwrap();
        }
        let source = CountingArchiveSource::new(writer.finish().unwrap().into_inner());
        let archive = zip::ZipArchive::new(ArchiveSourceReader::new(source.clone())).unwrap();
        let directoryReads = source.reads.load(Ordering::Relaxed);
        let mut archive = archive.clone();
        assert_eq!(source.reads.load(Ordering::Relaxed), directoryReads);
        for index in 0..archive.len() {
            let mut entry = archive.by_index(index).unwrap();
            let mut bytes = Vec::new();
            entry.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes, b"test payload");
        }
        assert!(source.reads.load(Ordering::Relaxed) < 128);
    }
}
