use super::*;

/// Exercises space join preserves identity members and exact revision through the device-space contract fixture.
#[test]
fn space_join_preserves_identity_members_and_exact_revision() {
    let current = CoreSpace {
        spaceId: "space".into(),
        spaceName: "name".into(),
        spaceRevision: 5,
        members: vec!["host".into()],
    };
    let valid = CoreSpace {
        spaceRevision: 6,
        members: vec!["host".into(), "joining".into()],
        ..current.clone()
    };
    assert!(validateSpaceJoin(&current, "joining", &valid).is_ok());
    assert!(validateSpaceJoin(&valid, "joining", &valid).is_ok());
    for proposal in [
        CoreSpace {
            spaceId: "other".into(),
            ..valid.clone()
        },
        CoreSpace {
            spaceName: "other".into(),
            ..valid.clone()
        },
        CoreSpace {
            spaceRevision: 5,
            ..valid.clone()
        },
        CoreSpace {
            spaceRevision: 7,
            ..valid.clone()
        },
        CoreSpace {
            members: vec!["joining".into()],
            ..valid.clone()
        },
        CoreSpace {
            members: vec!["host".into(), "joining".into(), "third".into()],
            ..valid.clone()
        },
        CoreSpace {
            members: vec!["host".into(), "joining".into(), "joining".into()],
            ..valid.clone()
        },
    ] {
        assert!(validateSpaceJoin(&current, "joining", &proposal).is_err());
    }
    let overflow = CoreSpace {
        spaceRevision: i64::MAX,
        ..current
    };
    assert!(validateSpaceJoin(&overflow, "joining", &valid).is_err());
    assert!(validateSpaceJoin(
        &valid,
        "host",
        &CoreSpace {
            spaceRevision: 7,
            ..valid.clone()
        }
    )
    .is_err());
}

/// Exercises overview subscription stops worker after last watch is dropped through the device-space contract fixture.
#[tokio::test]
async fn overview_subscription_stops_worker_after_last_watch_is_dropped() {
    let source = StateFlow::new(1);
    let (stop, mut stopped) = oneshot::channel::<()>();
    let watch = spaceOverviewSubscription(&source, stop);
    let anotherWatch = watch.clone();
    source.set_value(2);
    assert_eq!(watch.value(), 2);
    drop(watch);
    assert!(matches!(
        stopped.try_recv(),
        Err(oneshot::error::TryRecvError::Empty)
    ));
    source.set_value(3);
    assert_eq!(anotherWatch.value(), 3);
    drop(anotherWatch);
    // The worker can still own the source; it must not keep the guard alive.
    assert!(stopped.await.is_err());
    source.set_value(4);
}

/// Creates one paired-device projection for status mapping tests.
fn test_paired_device(device_id: &str) -> RuntimePairedDevice {
    RuntimePairedDevice {
        deviceId: device_id.to_string(),
        deviceInfo: LinkDeviceInfo {
            platform: "test".to_string(),
            model: "peer".to_string(),
        },
        inbound: false,
        outbound: true,
    }
}

/// Verifies paired-device statuses are driven only by active Peer Links.
#[test]
fn paired_device_statuses_follow_active_peer_links_only() {
    let statuses = pairedDeviceStatusesFromState(
        BTreeMap::from([
            ("node-b".to_string(), test_paired_device("node-b")),
            ("node-c".to_string(), test_paired_device("node-c")),
        ]),
        BTreeSet::from(["node-b".to_string()]),
    );

    assert_eq!(
        statuses.get("node-b"),
        Some(&RuntimePairedDeviceStatus::Online)
    );
    assert_eq!(
        statuses.get("node-c"),
        Some(&RuntimePairedDeviceStatus::Offline)
    );
}
