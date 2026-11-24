// Stable libarchive reader ABI exported by the macOS SDK's libarchive.tbd.
#include <stddef.h>
#include <sys/types.h>

struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_free(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
