// ignore_for_file: file_names

import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';

import 'WorkspaceSyntaxToken.dart';

/// Supplies color-only token styles so highlighting cannot alter wrapping.
class WorkspaceSyntaxPalette {
  /// Selects a shared palette through Flutter's theme brightness abstraction.
  const WorkspaceSyntaxPalette(this.brightness);

  final Brightness brightness;

  /// Returns a token color with distinct light and dark surface contrast.
  Color color(WorkspaceSyntaxTokenKind kind) {
    final dark = brightness == Brightness.dark;
    return switch (kind) {
      WorkspaceSyntaxTokenKind.keyword =>
        dark ? const Color(0xffc792ea) : const Color(0xff7c3aad),
      WorkspaceSyntaxTokenKind.type || WorkspaceSyntaxTokenKind.tag =>
        dark ? const Color(0xff82d9ce) : const Color(0xff007e78),
      WorkspaceSyntaxTokenKind.literal || WorkspaceSyntaxTokenKind.number =>
        dark ? const Color(0xfff7b782) : const Color(0xffa24a00),
      WorkspaceSyntaxTokenKind.string || WorkspaceSyntaxTokenKind.inserted =>
        dark ? const Color(0xffb6dc91) : const Color(0xff34772a),
      WorkspaceSyntaxTokenKind.comment =>
        dark ? const Color(0xff919eae) : const Color(0xff677483),
      WorkspaceSyntaxTokenKind.function || WorkspaceSyntaxTokenKind.heading =>
        dark ? const Color(0xff82b8ff) : const Color(0xff235fba),
      WorkspaceSyntaxTokenKind.property || WorkspaceSyntaxTokenKind.variable =>
        dark ? const Color(0xffefcb83) : const Color(0xff845b00),
      WorkspaceSyntaxTokenKind.operator ||
      WorkspaceSyntaxTokenKind.punctuation =>
        dark ? const Color(0xffb9c5d6) : const Color(0xff58667a),
      WorkspaceSyntaxTokenKind.meta || WorkspaceSyntaxTokenKind.link =>
        dark ? const Color(0xfff49eb9) : const Color(0xffaa3560),
      WorkspaceSyntaxTokenKind.deleted =>
        dark ? const Color(0xffff9292) : const Color(0xffbf3030),
    };
  }

  /// Produces a foreground-only span style, inheriting all paragraph metrics.
  TextStyle style(WorkspaceSyntaxTokenKind kind) =>
      TextStyle(color: color(kind));

  /// Compares palette appearance without invalidating unchanged render caches.
  @override
  bool operator ==(Object other) =>
      other is WorkspaceSyntaxPalette && other.brightness == brightness;

  /// Hashes the appearance shared by all highlighted paragraphs.
  @override
  int get hashCode => brightness.hashCode;
}
