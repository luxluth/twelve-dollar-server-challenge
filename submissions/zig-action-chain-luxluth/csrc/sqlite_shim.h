#ifndef SQLITE_SHIM_H
#define SQLITE_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int ac_db_open(const char *path);
void ac_db_close(void);
int ac_db_health(void);

int ac_db_begin_batch(void);
int ac_db_commit_batch(void);
void ac_db_rollback_batch(void);

// Zero-SQL direct B-tree read plans
int ac_db_feed(uint8_t *out_buf, size_t cap, size_t *out_len);
int ac_db_get_post(int64_t id, uint8_t *out_buf, size_t cap, size_t *out_len);

// Write operations (pre-compiled VDBE step)
int ac_db_create_post(int64_t user_id, const uint8_t *author, size_t author_len,
                      const uint8_t *body, size_t body_len,
                      uint8_t *out_buf, size_t cap, size_t *out_len);

// Returns 1 = liked (201), 2 = already liked (200), 0 = post not found (404), -1 = error
int ac_db_like(int64_t user_id, int64_t post_id);

int ac_db_writes_allowed(void);

#ifdef __cplusplus
}
#endif

#endif
