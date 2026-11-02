# LZ4 1.10.0 (the lib/ directory)
roadmap: S-8

From https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz, downloaded 2026-10-30 with the maintainer's go;
SHA-256 537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b, equal to the release's own .sha256 file.
Copied unchanged: `lib/lz4.c|h`, `lz4frame.c|h`, `lz4frame_static.h`, `lz4hc.c|h` (the frame code links against
them), `xxhash.c|h` and `lib/LICENSE` (BSD 2-clause; only lib/ is BSD, the programs are GPL and not copied). xxHash is
compiled with XXH_NAMESPACE=LZ4_ so it cannot collide with Zstandard's copy. Used only to decode .lz4 / .tar.lz4
frames for listing and member reads, in memory, bounded by the archive limits (G-15 correction of 2026-10-30).
