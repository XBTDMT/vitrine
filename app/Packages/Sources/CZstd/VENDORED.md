# Zstandard 1.5.7 (decompression only)
roadmap: S-8

From https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz, downloaded 2026-10-30 with the maintainer's
go; SHA-256 eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3, equal to the release's own .sha256 file.
Copied unchanged: `lib/common/*`, `lib/decompress/*.c|h` (not the x86-64 assembly), `lib/zstd.h`, `lib/zstd_errors.h`,
and `LICENSE` (used under the BSD licence; zstd is dual BSD / GPLv2). Built with ZSTD_DISABLE_ASM, no legacy formats,
no multithreading. Used only to decode .zst / .tar.zst for listing and member reads, in memory, bounded by the
archive limits (knowledge/decisions/G-15-archive-format-engine.md, correction of 2026-10-30).
