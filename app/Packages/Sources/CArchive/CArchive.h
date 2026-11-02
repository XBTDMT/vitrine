// Our own declarations of the part of libarchive's read API that VitrineArchive calls (G-15). macOS ships
// /usr/lib/libarchive.2.dylib and the SDK its libarchive.tbd, but no archive.h, so the prototypes below are written
// from libarchive's public, documented API (libarchive 3.x; this Mac's library reports 3.7.4). Only reading is
// declared: nothing here can write, extract to disk or start an external program (the `program` filters, which run
// helper binaries, are deliberately absent). roadmap: S-8
#ifndef VITRINE_CARCHIVE_H
#define VITRINE_CARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

// Status codes.
#define VITRINE_ARCHIVE_EOF 1
#define VITRINE_ARCHIVE_OK 0
#define VITRINE_ARCHIVE_RETRY (-10)
#define VITRINE_ARCHIVE_WARN (-20)
#define VITRINE_ARCHIVE_FAILED (-25)
#define VITRINE_ARCHIVE_FATAL (-30)

// The reader asks the client for bytes through these.
typedef ssize_t vitrine_archive_read_callback(struct archive *, void *client, const void **buffer);
typedef int64_t vitrine_archive_skip_callback(struct archive *, void *client, int64_t request);
typedef int64_t vitrine_archive_seek_callback(struct archive *, void *client, int64_t offset, int whence);

struct archive *archive_read_new(void);
int archive_read_free(struct archive *);

int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_compress(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_lz4(struct archive *);
int archive_read_support_filter_lzip(struct archive *);
int archive_read_support_filter_lzma(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_filter_zstd(struct archive *);
int archive_read_support_filter_rpm(struct archive *);

int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_ar(struct archive *);
int archive_read_support_format_cab(struct archive *);
int archive_read_support_format_cpio(struct archive *);
int archive_read_support_format_iso9660(struct archive *);
int archive_read_support_format_lha(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_xar(struct archive *);
int archive_read_support_format_zip_seekable(struct archive *);

int archive_read_set_read_callback(struct archive *, vitrine_archive_read_callback *);
int archive_read_set_skip_callback(struct archive *, vitrine_archive_skip_callback *);
int archive_read_set_seek_callback(struct archive *, vitrine_archive_seek_callback *);
int archive_read_set_callback_data(struct archive *, void *);
int archive_read_open1(struct archive *);

int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int64_t archive_read_header_position(struct archive *);
/// -2: the format cannot tell; -1: not known yet; 0: no encrypted entries so far; > 0: some.
int archive_read_has_encrypted_entries(struct archive *);

const char *archive_error_string(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
int archive_filter_code(struct archive *, int);
const char *archive_filter_name(struct archive *, int);
int64_t archive_filter_bytes(struct archive *, int);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_mode(struct archive_entry *);
int archive_entry_perm_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
int64_t archive_entry_uid(struct archive_entry *);
int64_t archive_entry_gid(struct archive_entry *);
int archive_entry_uid_is_set(struct archive_entry *);
int archive_entry_gid_is_set(struct archive_entry *);
const char *archive_entry_uname(struct archive_entry *);
const char *archive_entry_gname(struct archive_entry *);
dev_t archive_entry_rdevmajor(struct archive_entry *);
dev_t archive_entry_rdevminor(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
int archive_entry_is_data_encrypted(struct archive_entry *);
int archive_entry_is_metadata_encrypted(struct archive_entry *);

#endif
