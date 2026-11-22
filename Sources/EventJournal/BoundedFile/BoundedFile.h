#ifndef BOUNDED_FILE_H
#define BOUNDED_FILE_H
#include <sqlite3.h>

#define MAIN_FILE_LIMIT ((sqlite3_int64)512 << 20)
#define JOURNAL_FILE_LIMIT ((sqlite3_int64)768 << 20)

int bounded_storage_size(int nativeSize);
sqlite3_file *bounded_native_storage(sqlite3_file *outer);
int bounded_install(sqlite3_file *outer, sqlite3_int64 limit);
#endif
