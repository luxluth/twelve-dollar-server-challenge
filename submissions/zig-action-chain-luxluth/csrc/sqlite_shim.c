#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <stdatomic.h>
#include <time.h>

#define SQLITE_THREADSAFE 2
#define SQLITE_DEFAULT_MEMSTATUS 0
#define SQLITE_DEFAULT_WAL_SYNCHRONOUS 1
#define SQLITE_DQS 0
#define SQLITE_LIKE_DOESNT_MATCH_BLOBS 1
#define SQLITE_MAX_EXPR_DEPTH 0
#define SQLITE_OMIT_DEPRECATED 1
#define SQLITE_OMIT_SHARED_CACHE 1
#define SQLITE_OMIT_PROGRESS_CALLBACK 1
#define SQLITE_OMIT_AUTOINIT 1
#define SQLITE_OMIT_LOAD_EXTENSION 1
#define SQLITE_USE_ALLOCA 1
#define SQLITE_TEMP_STORE 3
#define HAVE_USLEEP 1
#define HAVE_FDATASYNC 1

#include "sqlite3.c"
#include "sqlite_shim.h"

#define FEED_N 20
#define FEED_SPAN 256
#define WAL_WAKE_FRAMES 1000
#define WAL_GATE_FRAMES 4000
#define WAL_INLINE_FRAMES 16384
#define WAL_GATE_MAX_NS 1000000000ULL

/* ---------------- JSON output builder ---------------- */

struct ob {
  uint8_t *b;
  size_t n, cap;
  int err;
};

static inline void ob_init(struct ob *o, uint8_t *b, size_t cap) {
  o->b = b;
  o->n = 0;
  o->cap = cap;
  o->err = 0;
}

static inline void ob_bytes(struct ob *o, const void *p, size_t n) {
  if (o->n + n > o->cap) { o->err = 1; return; }
  memcpy(o->b + o->n, p, n);
  o->n += n;
}

#define ob_lit(o, s) ob_bytes((o), (s), sizeof(s) - 1)

static inline void ob_char(struct ob *o, char c) {
  if (o->n >= o->cap) { o->err = 1; return; }
  o->b[o->n++] = (uint8_t)c;
}

static const char digits2[201] =
  "00010203040506070809101112131415161718192021222324252627282930313233343536373839"
  "40414243444546474849505152535455565758596061626364656667686970717273747576777879"
  "8081828384858687888990919293949596979899";

static inline unsigned u64_to_str(char *dst, uint64_t v) {
  char tmp[20];
  unsigned i = 20;
  while (v >= 100) {
    unsigned r = (unsigned)(v % 100);
    v /= 100;
    i -= 2;
    memcpy(tmp + i, digits2 + r * 2, 2);
  }
  if (v >= 10) {
    i -= 2;
    memcpy(tmp + i, digits2 + v * 2, 2);
  } else {
    tmp[--i] = (char)('0' + v);
  }
  memcpy(dst, tmp + i, 20 - i);
  return 20 - i;
}

static inline void ob_u64(struct ob *o, uint64_t v) {
  if (o->n + 20 > o->cap) { o->err = 1; return; }
  o->n += u64_to_str((char *)o->b + o->n, v);
}

typedef unsigned char u8x16 __attribute__((vector_size(16)));
static inline int needs_escape16(const uint8_t *p) {
  u8x16 v;
  memcpy(&v, p, 16);
  const u8x16 ctl = {0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20};
  const u8x16 quo = {'"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"'};
  const u8x16 bsl = {'\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\', '\\'};
  __typeof__(v < ctl) m = (v < ctl) | (v == quo) | (v == bsl);
  uint64_t a, b;
  memcpy(&a, &m, 8);
  memcpy(&b, (const char *)&m + 8, 8);
  return (a | b) != 0;
}

static void ob_json_str(struct ob *o, const uint8_t *s, size_t n) {
  if (o->n + n + 2 > o->cap) { o->err = 1; return; }
  o->b[o->n++] = '"';
  size_t i = 0;
  while (i < n) {
    size_t run = i;
    while (run + 16 <= n && !needs_escape16(s + run)) run += 16;
    while (run + 8 <= n) {
      uint64_t w;
      memcpy(&w, s + run, 8);
      uint64_t lt20 = (w - 0x2020202020202020ULL) & ~w & 0x8080808080808080ULL;
      uint64_t q = w ^ 0x2222222222222222ULL;
      uint64_t isq = (q - 0x0101010101010101ULL) & ~q & 0x8080808080808080ULL;
      uint64_t bs = w ^ 0x5c5c5c5c5c5c5c5cULL;
      uint64_t isbs = (bs - 0x0101010101010101ULL) & ~bs & 0x8080808080808080ULL;
      if (lt20 | isq | isbs) break;
      run += 8;
    }
    while (run < n && s[run] >= 0x20 && s[run] != '"' && s[run] != '\\') run++;
    if (run > i) {
      if (o->n + (run - i) > o->cap) { o->err = 1; return; }
      memcpy(o->b + o->n, s + i, run - i);
      o->n += run - i;
      i = run;
    }
    if (i >= n) break;
    uint8_t c = s[i++];
    if (o->n + 6 > o->cap) { o->err = 1; return; }
    o->b[o->n++] = '\\';
    switch (c) {
    case '"': o->b[o->n++] = '"'; break;
    case '\\': o->b[o->n++] = '\\'; break;
    case '\n': o->b[o->n++] = 'n'; break;
    case '\r': o->b[o->n++] = 'r'; break;
    case '\t': o->b[o->n++] = 't'; break;
    case '\b': o->b[o->n++] = 'b'; break;
    case '\f': o->b[o->n++] = 'f'; break;
    default: {
      static const char hx[] = "0123456789abcdef";
      o->b[o->n++] = 'u'; o->b[o->n++] = '0'; o->b[o->n++] = '0';
      o->b[o->n++] = (uint8_t)hx[c >> 4]; o->b[o->n++] = (uint8_t)hx[c & 15];
    }
    }
  }
  if (o->n >= o->cap) { o->err = 1; return; }
  o->b[o->n++] = '"';
}

static inline void ob_post_obj(struct ob *o, int64_t id, const uint8_t *body, int body_n,
                               const uint8_t *created, int created_n,
                               const uint8_t *author, int author_n, int64_t likes) {
  ob_lit(o, "{\"id\":");
  ob_u64(o, (uint64_t)id);
  ob_lit(o, ",\"body\":");
  ob_json_str(o, body, (size_t)body_n);
  ob_lit(o, ",\"created_at\":");
  ob_json_str(o, created, (size_t)created_n);
  ob_lit(o, ",\"author\":");
  ob_json_str(o, author, (size_t)author_n);
  ob_lit(o, ",\"like_count\":");
  ob_u64(o, (uint64_t)likes);
  ob_char(o, '}');
}

/* ---------------- B-Tree internals ---------------- */

struct bt_cursor {
  BtCursor *c;
};

struct bt {
  Btree *bt;
  Pgno root_posts, root_users, root_likes_idx, root_posts_idx;
  KeyInfo *ki_likes_idx, *ki_posts_idx;
  struct bt_cursor posts, users, likes_idx, posts_idx;
  int open;
  int ok;
  uint8_t *spill;
  uint32_t spill_cap;
};

struct rec {
  const u8 *p;
  u32 n;
};

struct col {
  u64 t;
  const u8 *p;
};

static Pgno bt_rootpage(sqlite3 *c, const char *name) {
  sqlite3_stmt *s;
  if (sqlite3_prepare_v2(c, "SELECT rootpage FROM sqlite_schema WHERE name = ?1", -1, &s, NULL) != SQLITE_OK) return 0;
  sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
  Pgno r = sqlite3_step(s) == SQLITE_ROW ? (Pgno)sqlite3_column_int64(s, 0) : 0;
  sqlite3_finalize(s);
  return r;
}

static int bt_table_layout(sqlite3 *c, const char *table, const char *expect) {
  char sql[128], got[512];
  snprintf(sql, sizeof sql, "PRAGMA table_info(\"%s\")", table);
  sqlite3_stmt *s;
  if (sqlite3_prepare_v2(c, sql, -1, &s, NULL) != SQLITE_OK) return 0;
  size_t n = 0;
  got[0] = 0;
  while (sqlite3_step(s) == SQLITE_ROW && n < sizeof got)
    n += (size_t)snprintf(got + n, sizeof got - n, "%s%s:%s:%d", n ? "," : "", sqlite3_column_text(s, 1),
                          sqlite3_column_text(s, 2), sqlite3_column_int(s, 5));
  sqlite3_finalize(s);
  return strcmp(got, expect) == 0;
}

static int bt_index_layout(sqlite3 *c, const char *index, const char *expect) {
  char sql[128], got[256];
  snprintf(sql, sizeof sql, "PRAGMA index_xinfo(\"%s\")", index);
  sqlite3_stmt *s;
  if (sqlite3_prepare_v2(c, sql, -1, &s, NULL) != SQLITE_OK) return 0;
  size_t n = 0;
  got[0] = 0;
  while (sqlite3_step(s) == SQLITE_ROW && n < sizeof got) {
    if (!sqlite3_column_int(s, 5)) continue;
    n += (size_t)snprintf(got + n, sizeof got - n, "%s%s:%d", n ? "," : "", sqlite3_column_text(s, 2), sqlite3_column_int(s, 3));
  }
  sqlite3_finalize(s);
  return strcmp(got, expect) == 0;
}

static KeyInfo *bt_keyinfo(sqlite3 *c, int nkey, int nextra, int desc) {
  KeyInfo *k = sqlite3KeyInfoAlloc(c, nkey, nextra);
  if (!k) return NULL;
  for (int i = 0; i < nkey + nextra; i++) {
    k->aColl[i] = c->pDfltColl;
    if (desc && i < nkey) k->aSortFlags[i] = KEYINFO_ORDER_DESC;
  }
  return k;
}

static int bt_init(struct bt *b, sqlite3 *c) {
  memset(b, 0, sizeof *b);
  b->bt = c->aDb[0].pBt;
  int ok = bt_table_layout(c, "users", "id:INTEGER:1,username:TEXT:0,created_at:TEXT:0") &&
           bt_table_layout(c, "posts", "id:INTEGER:1,user_id:INTEGER:0,body:TEXT:0,created_at:TEXT:0") &&
           bt_table_layout(c, "likes", "user_id:INTEGER:1,post_id:INTEGER:2,created_at:TEXT:0") &&
           bt_index_layout(c, "likes_post_id_idx", "post_id:0") &&
           bt_index_layout(c, "posts_created_at_id_idx", "created_at:1,id:1");
  b->root_posts = bt_rootpage(c, "posts");
  b->root_users = bt_rootpage(c, "users");
  b->root_likes_idx = bt_rootpage(c, "likes_post_id_idx");
  b->root_posts_idx = bt_rootpage(c, "posts_created_at_id_idx");
  if (!ok || !b->root_posts || !b->root_users || !b->root_likes_idx || !b->root_posts_idx) return 0;

  b->ki_likes_idx = bt_keyinfo(c, 1, 1, 0);
  b->ki_posts_idx = bt_keyinfo(c, 2, 1, 1);
  size_t sz = (size_t)sqlite3BtreeCursorSize();
  b->posts.c = malloc(sz);
  b->users.c = malloc(sz);
  b->likes_idx.c = malloc(sz);
  b->posts_idx.c = malloc(sz);
  if (!b->ki_likes_idx || !b->ki_posts_idx || !b->posts.c || !b->users.c || !b->likes_idx.c || !b->posts_idx.c) return 0;
  b->ok = 1;
  return 1;
}

static int bt_open(struct bt *b) {
  if (!b->ok || b->open) return 0;
  if (sqlite3BtreeBeginTrans(b->bt, 0, 0) != SQLITE_OK) return -1;
  sqlite3BtreeCursorZero(b->posts.c);
  sqlite3BtreeCursorZero(b->users.c);
  sqlite3BtreeCursorZero(b->likes_idx.c);
  sqlite3BtreeCursorZero(b->posts_idx.c);
  if (sqlite3BtreeCursor(b->bt, b->root_posts, 0, NULL, b->posts.c) != SQLITE_OK ||
      sqlite3BtreeCursor(b->bt, b->root_users, 0, NULL, b->users.c) != SQLITE_OK ||
      sqlite3BtreeCursor(b->bt, b->root_likes_idx, 0, b->ki_likes_idx, b->likes_idx.c) != SQLITE_OK ||
      sqlite3BtreeCursor(b->bt, b->root_posts_idx, 0, b->ki_posts_idx, b->posts_idx.c) != SQLITE_OK)
    return -1;
  b->open = 1;
  return 0;
}

static void bt_close(struct bt *b) {
  if (!b->open) return;
  sqlite3BtreeCloseCursor(b->posts.c);
  sqlite3BtreeCloseCursor(b->users.c);
  sqlite3BtreeCloseCursor(b->likes_idx.c);
  sqlite3BtreeCloseCursor(b->posts_idx.c);
  b->open = 0;
}

static int bt_record(struct bt *b, struct bt_cursor *c, struct rec *r) {
  u32 total = sqlite3BtreePayloadSize(c->c), local;
  const u8 *p = sqlite3BtreePayloadFetch(c->c, &local);
  if (local == total) { r->p = p; r->n = total; return 0; }
  if (total > b->spill_cap) {
    free(b->spill);
    b->spill_cap = total + 4096;
    b->spill = malloc(b->spill_cap);
    if (!b->spill) return -1;
  }
  if (sqlite3BtreePayload(c->c, 0, total, b->spill) != SQLITE_OK) return -1;
  r->p = b->spill;
  r->n = total;
  return 0;
}

static inline const u8 *rd_varint(const u8 *p, const u8 *end, u64 *v) {
  u64 x = 0;
  for (int i = 0; i < 8; i++) {
    if (p >= end) return NULL;
    x = x << 7 | (p[0] & 0x7f);
    if (!(*p++ & 0x80)) { *v = x; return p; }
  }
  if (p >= end) return NULL;
  *v = x << 8 | *p++;
  return p;
}

static inline u32 serial_len(u64 t) {
  static const u8 n[12] = {0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0};
  return t < 12 ? n[t] : (u32)((t - 12) / 2);
}

static inline int rec_cols(const struct rec *r, int ncol, struct col *c) {
  const u8 *end = r->p + r->n;
  u64 hsz;
  const u8 *h = rd_varint(r->p, end, &hsz);
  if (!h || hsz > r->n) return -1;
  const u8 *hend = r->p + hsz, *body = hend;
  for (int i = 0; i < ncol; i++) {
    if (h >= hend) return -1;
    h = rd_varint(h, hend, &c[i].t);
    if (!h) return -1;
    c[i].p = body;
    body += serial_len(c[i].t);
  }
  return body <= end ? 0 : -1;
}

static inline int col_is_int(const struct col *c) { return (c->t >= 1 && c->t <= 6) || c->t == 8 || c->t == 9; }
static inline int col_is_text(const struct col *c) { return c->t >= 13 && (c->t & 1); }
static inline u32 col_len(const struct col *c) { return serial_len(c->t); }
static inline i64 col_int(const struct col *c) {
  const u8 *p = c->p;
  switch (c->t) {
  case 1: return (int8_t)p[0];
  case 2: return (int16_t)((u16)p[0] << 8 | p[1]);
  case 3: return (int32_t)((u32)p[0] << 24 | (u32)p[1] << 16 | (u32)p[2] << 8) >> 8;
  case 4: return (int32_t)((u32)p[0] << 24 | (u32)p[1] << 16 | (u32)p[2] << 8 | p[3]);
  case 5: return (i64)((u64)(int16_t)((u16)p[0] << 8 | p[1]) << 32 | (u64)((u32)p[2] << 24 | (u32)p[3] << 16 | (u32)p[4] << 8 | p[5]));
  case 6: { u64 v = 0; for (int i = 0; i < 8; i++) v = v << 8 | p[i]; return (i64)v; }
  case 8: return 0;
  case 9: return 1;
  default: return 0;
  }
}

static inline int cur_first(struct bt_cursor *c) {
  int empty;
  return sqlite3BtreeFirst(c->c, &empty) != SQLITE_OK ? -1 : empty ? 1 : 0;
}
static inline int cur_next(struct bt_cursor *c) {
  int rc = sqlite3BtreeNext(c->c, 0);
  return rc == SQLITE_OK ? 0 : rc == SQLITE_DONE ? 1 : -1;
}
static inline int cur_seek(struct bt_cursor *c, i64 rowid) {
  int res;
  if (sqlite3BtreeTableMoveto(c->c, rowid, 0, &res) != SQLITE_OK) return -1;
  return res == 0 ? 0 : 1;
}

static int idx_seek_ge(struct bt_cursor *c, KeyInfo *ki, i64 k) {
  Mem m;
  memset(&m, 0, sizeof m);
  m.flags = MEM_Int;
  m.u.i = k;
  UnpackedRecord r;
  memset(&r, 0, sizeof r);
  r.pKeyInfo = ki;
  r.aMem = &m;
  r.nField = 1;
  r.default_rc = +1;
  int res;
  if (sqlite3BtreeIndexMoveto(c->c, &r, &res) != SQLITE_OK) return -1;
  if (res < 0) return cur_next(c);
  return sqlite3BtreeEof(c->c) ? 1 : 0;
}

static int bt_range_counts(struct bt *b, i64 lo, i64 hi, i64 *counts) {
  memset(counts, 0, sizeof(i64) * (size_t)(hi - lo + 1));
  int rc = idx_seek_ge(&b->likes_idx, b->ki_likes_idx, lo);
  while (rc == 0) {
    struct rec r;
    struct col c[1];
    if (bt_record(b, &b->likes_idx, &r) || rec_cols(&r, 1, c) || !col_is_int(&c[0])) return -1;
    i64 pid = col_int(&c[0]);
    if (pid > hi) return 0;
    counts[pid - lo]++;
    rc = cur_next(&b->likes_idx);
  }
  return rc < 0 ? -1 : 0;
}

static int bt_user_name(struct bt *b, i64 uid, const u8 **name, u32 *len) {
  int rc = cur_seek(&b->users, uid);
  if (rc) return rc;
  struct rec r;
  struct col c[2];
  if (bt_record(b, &b->users, &r) || rec_cols(&r, 2, c) || !col_is_text(&c[1])) return -1;
  *name = c[1].p;
  *len = col_len(&c[1]);
  return 0;
}

static int table_seek_ge(struct bt_cursor *c, i64 key) {
  int res;
  if (sqlite3BtreeTableMoveto(c->c, key, 0, &res) != SQLITE_OK) return -1;
  if (sqlite3BtreeEof(c->c)) return 1;
  if (res < 0) return cur_next(c);
  return 0;
}

static int bt_feed(struct bt *b, struct ob *o) {
  i64 ids[FEED_N];
  int n = 0;
  int rc = cur_first(&b->posts_idx);
  while (rc == 0 && n < FEED_N) {
    struct rec r;
    struct col c[2];
    if (bt_record(b, &b->posts_idx, &r) || rec_cols(&r, 2, c) || !col_is_text(&c[0]) || !col_is_int(&c[1])) return -1;
    ids[n++] = col_int(&c[1]);
    rc = cur_next(&b->posts_idx);
  }
  if (rc < 0) return -1;
  if (n == 0) { ob_lit(o, "{\"posts\":[]}"); return 0; }
  i64 lo = ids[0], hi = ids[0];
  for (int i = 1; i < n; i++) {
    if (ids[i] < lo) lo = ids[i];
    if (ids[i] > hi) hi = ids[i];
  }
  if (hi - lo >= FEED_SPAN) return -1;
  i64 counts[FEED_SPAN];
  if (bt_range_counts(b, lo, hi, counts)) return -1;

  int8_t slot[FEED_SPAN];
  memset(slot, -1, sizeof slot);
  for (int i = 0; i < n; i++) slot[ids[i] - lo] = (int8_t)i;
  static u8 bodies[FEED_N][2048], created[FEED_N][64];
  u32 body_len[FEED_N], created_len[FEED_N];
  i64 uids[FEED_N];
  int found = 0;
  rc = table_seek_ge(&b->posts, lo);
  while (rc == 0) {
    i64 id = sqlite3BtreeIntegerKey(b->posts.c);
    if (id > hi) break;
    int i = slot[id - lo];
    if (i >= 0) {
      struct rec r;
      struct col c[4];
      if (bt_record(b, &b->posts, &r) || rec_cols(&r, 4, c) || !col_is_int(&c[1]) || !col_is_text(&c[2]) || !col_is_text(&c[3]))
        return -1;
      body_len[i] = col_len(&c[2]);
      created_len[i] = col_len(&c[3]);
      if (body_len[i] > sizeof bodies[i] || created_len[i] > sizeof created[i]) return -1;
      memcpy(bodies[i], c[2].p, body_len[i]);
      memcpy(created[i], c[3].p, created_len[i]);
      uids[i] = col_int(&c[1]);
      if (++found == n) break;
    }
    rc = cur_next(&b->posts);
  }
  if (rc < 0 || found != n) return -1;

  const u8 *names[FEED_N];
  u32 name_len[FEED_N];
  for (int i = 0; i < n; i++) {
    if (bt_user_name(b, uids[i], &names[i], &name_len[i])) return -1;
  }

  ob_lit(o, "{\"posts\":[");
  for (int i = 0; i < n; i++) {
    if (i) ob_char(o, ',');
    ob_post_obj(o, ids[i], bodies[i], (int)body_len[i], created[i], (int)created_len[i], names[i], (int)name_len[i],
                counts[ids[i] - lo]);
  }
  ob_lit(o, "]}");
  return 0;
}

static int bt_post_obj(struct bt *b, struct ob *o, i64 id, i64 likes) {
  int rc = cur_seek(&b->posts, id);
  if (rc) return rc;
  struct rec r;
  struct col c[4];
  if (bt_record(b, &b->posts, &r) || rec_cols(&r, 4, c) || !col_is_int(&c[1]) || !col_is_text(&c[2]) || !col_is_text(&c[3]))
    return -1;
  u32 bl = col_len(&c[2]), cl = col_len(&c[3]);
  u8 body[2048], created[64];
  if (bl > sizeof body || cl > sizeof created) return -1;
  memcpy(body, c[2].p, bl);
  memcpy(created, c[3].p, cl);
  const u8 *name;
  u32 nl;
  i64 uid = col_int(&c[1]);
  if (bt_user_name(b, uid, &name, &nl)) return -1;
  ob_post_obj(o, id, body, (int)bl, created, (int)cl, name, (int)nl, likes);
  return 0;
}

static int bt_post(struct bt *b, struct ob *o, i64 id) {
  i64 likes;
  if (bt_range_counts(b, id, id, &likes)) return -1;
  ob_lit(o, "{\"post\":");
  int rc = bt_post_obj(b, o, id, likes);
  if (rc < 0) return -1;
  if (rc == 1) return 0;
  ob_char(o, '}');
  return 1;
}

static int bt_post_exists(struct bt *b, i64 id) {
  return cur_seek(&b->posts, id);
}

/* ---------------- Database context ---------------- */

struct db_ctx {
  sqlite3 *c;
  sqlite3 *c2;
  struct bt bt;
  sqlite3_stmt *st_begin;
  sqlite3_stmt *st_commit;
  sqlite3_stmt *st_rollback;
  sqlite3_stmt *st_health;
  sqlite3_stmt *st_feed_ref;
  sqlite3_stmt *st_post;
  sqlite3_stmt *st_ins_post;
  sqlite3_stmt *st_created_at;
  sqlite3_stmt *st_ins_like;
  sqlite3_stmt *st_post_exists;
  int in_txn;
  int wrote;
  // checkpoint
  pthread_t ckpt_thr;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int wanted, stop;
  _Atomic uint64_t commit_seq;
  _Atomic uint64_t backfilled_seq;
  _Atomic int wal_frames;
  int gate_held;
  uint64_t gate_since;
};

static struct db_ctx G_DB;

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int db_wal_hook(void *ud, sqlite3 *c, const char *name, int frames) {
  (void)c; (void)name;
  struct db_ctx *d = (struct db_ctx *)ud;
  atomic_store_explicit(&d->wal_frames, frames, memory_order_relaxed);
  atomic_fetch_add_explicit(&d->commit_seq, 1, memory_order_release);
  if (frames >= WAL_WAKE_FRAMES) {
    if (frames >= WAL_GATE_FRAMES && !d->gate_held) {
      d->gate_held = 1;
      d->gate_since = now_ns();
    }
    pthread_mutex_lock(&d->mu);
    d->wanted = 1;
    pthread_cond_signal(&d->cv);
    pthread_mutex_unlock(&d->mu);
  }
  return SQLITE_OK;
}

static void *db_ckpt_thread(void *ud) {
  struct db_ctx *d = (struct db_ctx *)ud;
  setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);
  pthread_setname_np(pthread_self(), "ckpt");
  for (;;) {
    pthread_mutex_lock(&d->mu);
    while (!d->wanted && !d->stop) {
      struct timespec ts;
      clock_gettime(CLOCK_REALTIME, &ts);
      ts.tv_nsec += 250000000L;
      if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
      pthread_cond_timedwait(&d->cv, &d->mu, &ts);
    }
    if (d->stop) { pthread_mutex_unlock(&d->mu); return NULL; }
    d->wanted = 0;
    pthread_mutex_unlock(&d->mu);
    uint64_t seq = atomic_load_explicit(&d->commit_seq, memory_order_acquire);
    int nlog = 0, nckpt = 0;
    int rc = sqlite3_wal_checkpoint_v2(d->c2, "main", SQLITE_CHECKPOINT_PASSIVE, &nlog, &nckpt);
    if ((rc == SQLITE_OK || rc == SQLITE_BUSY) && nlog == nckpt)
      atomic_store_explicit(&d->backfilled_seq, seq, memory_order_release);
    if (d->gate_held && !(nlog == nckpt)) {
      pthread_mutex_lock(&d->mu);
      d->wanted = 1;
      pthread_mutex_unlock(&d->mu);
    }
  }
}

static int db_open_conn(sqlite3 **out, const char *path, long long mmap_bytes, int cache_kib) {
  int rc = sqlite3_open_v2(path, out, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE, NULL);
  if (rc != SQLITE_OK) return -1;
  char sql[128];
  snprintf(sql, sizeof sql, "PRAGMA mmap_size=%lld", mmap_bytes);
  sqlite3_exec(*out, sql, NULL, NULL, NULL);
  snprintf(sql, sizeof sql, "PRAGMA cache_size=-%d", cache_kib);
  sqlite3_exec(*out, sql, NULL, NULL, NULL);
  sqlite3_exec(*out, "PRAGMA synchronous=NORMAL", NULL, NULL, NULL);
  sqlite3_exec(*out, "PRAGMA temp_store=MEMORY", NULL, NULL, NULL);
  sqlite3_exec(*out, "PRAGMA wal_autocheckpoint=0", NULL, NULL, NULL);
  sqlite3_busy_timeout(*out, 2000);
  return 0;
}

static inline void ob_post_row(struct ob *o, sqlite3_stmt *st, int64_t likes) {
  ob_post_obj(o, sqlite3_column_int64(st, 0), sqlite3_column_text(st, 1), sqlite3_column_bytes(st, 1),
              sqlite3_column_text(st, 2), sqlite3_column_bytes(st, 2), sqlite3_column_text(st, 3),
              sqlite3_column_bytes(st, 3), likes);
}

int ac_db_open(const char *path) {
  memset(&G_DB, 0, sizeof G_DB);
  if (sqlite3_initialize() != SQLITE_OK) return -1;
  if (db_open_conn(&G_DB.c, path, 268435456LL, 64000) < 0) return -1;

  sqlite3_stmt *jm;
  if (sqlite3_prepare_v2(G_DB.c, "PRAGMA journal_mode=WAL", -1, &jm, NULL) != SQLITE_OK) return -1;
  int rc = sqlite3_step(jm);
  if (rc != SQLITE_ROW || strcmp((const char *)sqlite3_column_text(jm, 0), "wal") != 0) {
    sqlite3_finalize(jm);
    return -1;
  }
  sqlite3_finalize(jm);

  if (sqlite3_prepare_v2(G_DB.c, "BEGIN", -1, &G_DB.st_begin, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c, "COMMIT", -1, &G_DB.st_commit, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c, "ROLLBACK", -1, &G_DB.st_rollback, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c, "SELECT 1", -1, &G_DB.st_health, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c,
        "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) "
        "FROM posts p JOIN users u ON u.id = p.user_id ORDER BY p.created_at DESC, p.id DESC LIMIT 20",
        -1, &G_DB.st_feed_ref, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c,
        "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) "
        "FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?1",
        -1, &G_DB.st_post, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c, "INSERT INTO posts (user_id, body) VALUES (?1, ?2)", -1, &G_DB.st_ins_post, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c, "SELECT created_at FROM posts WHERE id = ?1", -1, &G_DB.st_created_at, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c,
        "INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?2) "
        "ON CONFLICT (user_id, post_id) DO NOTHING",
        -1, &G_DB.st_ins_like, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(G_DB.c, "SELECT 1 FROM posts WHERE id = ?1", -1, &G_DB.st_post_exists, NULL) != SQLITE_OK)
    return -1;

  // Warm page cache with feed query
  while (sqlite3_step(G_DB.st_feed_ref) == SQLITE_ROW) {}
  sqlite3_reset(G_DB.st_feed_ref);

  bt_init(&G_DB.bt, G_DB.c);

  sqlite3_wal_hook(G_DB.c, db_wal_hook, &G_DB);

  pthread_mutex_init(&G_DB.mu, NULL);
  pthread_cond_init(&G_DB.cv, NULL);
  if (db_open_conn(&G_DB.c2, path, 0, 2048) < 0) return -1;
  if (pthread_create(&G_DB.ckpt_thr, NULL, db_ckpt_thread, &G_DB) != 0) return -1;

  return 0;
}

void ac_db_close(void) {
  if (G_DB.c) {
    if (G_DB.in_txn) ac_db_commit_batch();
    pthread_mutex_lock(&G_DB.mu);
    G_DB.stop = 1;
    pthread_cond_signal(&G_DB.cv);
    pthread_mutex_unlock(&G_DB.mu);
    pthread_join(G_DB.ckpt_thr, NULL);

    sqlite3_finalize(G_DB.st_begin);
    sqlite3_finalize(G_DB.st_commit);
    sqlite3_finalize(G_DB.st_rollback);
    sqlite3_finalize(G_DB.st_health);
    sqlite3_finalize(G_DB.st_feed_ref);
    sqlite3_finalize(G_DB.st_post);
    sqlite3_finalize(G_DB.st_ins_post);
    sqlite3_finalize(G_DB.st_created_at);
    sqlite3_finalize(G_DB.st_ins_like);
    sqlite3_finalize(G_DB.st_post_exists);

    sqlite3_close(G_DB.c2);
    sqlite3_close(G_DB.c);
  }
}

int ac_db_health(void) {
  int rc = sqlite3_step(G_DB.st_health);
  sqlite3_reset(G_DB.st_health);
  return rc == SQLITE_ROW ? 0 : -1;
}

int ac_db_begin_batch(void) {
  if (G_DB.in_txn) return 0;
  int rc = sqlite3_step(G_DB.st_begin);
  sqlite3_reset(G_DB.st_begin);
  if (rc != SQLITE_DONE) return -1;
  G_DB.in_txn = 1;
  G_DB.wrote = 0;
  if (G_DB.bt.ok) {
    if (bt_open(&G_DB.bt) < 0) G_DB.bt.ok = 0;
  }
  return 0;
}

int ac_db_commit_batch(void) {
  if (!G_DB.in_txn) return 0;
  G_DB.in_txn = 0;
  bt_close(&G_DB.bt);
  int rc = sqlite3_step(G_DB.st_commit);
  sqlite3_reset(G_DB.st_commit);
  if (rc == SQLITE_DONE) return 0;
  sqlite3_step(G_DB.st_rollback);
  sqlite3_reset(G_DB.st_rollback);
  return -1;
}

void ac_db_rollback_batch(void) {
  if (!G_DB.in_txn) return;
  G_DB.in_txn = 0;
  bt_close(&G_DB.bt);
  sqlite3_step(G_DB.st_rollback);
  sqlite3_reset(G_DB.st_rollback);
}

int ac_db_writes_allowed(void) {
  if (G_DB.gate_held) {
    uint64_t seq = atomic_load_explicit(&G_DB.commit_seq, memory_order_acquire);
    if (atomic_load_explicit(&G_DB.backfilled_seq, memory_order_acquire) == seq || now_ns() - G_DB.gate_since > WAL_GATE_MAX_NS)
      G_DB.gate_held = 0;
  }
  if (atomic_load_explicit(&G_DB.wal_frames, memory_order_relaxed) >= WAL_INLINE_FRAMES && !G_DB.in_txn) {
    int nlog = 0, nckpt = 0;
    sqlite3_wal_checkpoint_v2(G_DB.c, "main", SQLITE_CHECKPOINT_PASSIVE, &nlog, &nckpt);
    if (nlog == nckpt) {
      atomic_store_explicit(&G_DB.wal_frames, 0, memory_order_relaxed);
      G_DB.gate_held = 0;
    }
  }
  return !G_DB.gate_held;
}

int ac_db_feed(uint8_t *out_buf, size_t cap, size_t *out_len) {
  struct ob o;
  ob_init(&o, out_buf, cap);
  if (G_DB.bt.open) {
    if (bt_feed(&G_DB.bt, &o) == 0 && !o.err) {
      *out_len = o.n;
      return 0;
    }
    o.n = 0;
    o.err = 0;
  }
  // SQL fallback
  ob_lit(&o, "{\"posts\":[");
  int n = 0, rc;
  while ((rc = sqlite3_step(G_DB.st_feed_ref)) == SQLITE_ROW) {
    if (n++) ob_char(&o, ',');
    ob_post_row(&o, G_DB.st_feed_ref, sqlite3_column_int64(G_DB.st_feed_ref, 4));
  }
  sqlite3_reset(G_DB.st_feed_ref);
  if (rc != SQLITE_DONE || o.err) return -1;
  ob_lit(&o, "]}");
  *out_len = o.n;
  return 0;
}

int ac_db_get_post(int64_t id, uint8_t *out_buf, size_t cap, size_t *out_len) {
  struct ob o;
  ob_init(&o, out_buf, cap);
  if (G_DB.bt.open) {
    int rc = bt_post(&G_DB.bt, &o, id);
    if (rc >= 0 && !o.err) {
      if (rc == 0) return 0; // not found
      *out_len = o.n;
      return 1; // found
    }
    o.n = 0;
    o.err = 0;
  }
  // SQL fallback
  sqlite3_bind_int64(G_DB.st_post, 1, id);
  int rc = sqlite3_step(G_DB.st_post);
  int ret;
  if (rc == SQLITE_ROW) {
    ob_lit(&o, "{\"post\":");
    ob_post_row(&o, G_DB.st_post, sqlite3_column_int64(G_DB.st_post, 4));
    ob_char(&o, '}');
    *out_len = o.n;
    ret = 1;
  } else {
    ret = rc == SQLITE_DONE ? 0 : -1;
  }
  sqlite3_reset(G_DB.st_post);
  return ret;
}

int ac_db_create_post(int64_t user_id, const uint8_t *author, size_t author_len,
                      const uint8_t *body, size_t body_len,
                      uint8_t *out_buf, size_t cap, size_t *out_len) {
  sqlite3_bind_int64(G_DB.st_ins_post, 1, user_id);
  sqlite3_bind_text(G_DB.st_ins_post, 2, (const char *)body, (int)body_len, SQLITE_STATIC);
  int rc = sqlite3_step(G_DB.st_ins_post);
  sqlite3_reset(G_DB.st_ins_post);
  if (rc != SQLITE_DONE) return -1;
  G_DB.wrote = 1;

  int64_t id = sqlite3_last_insert_rowid(G_DB.c);
  sqlite3_bind_int64(G_DB.st_created_at, 1, id);
  rc = sqlite3_step(G_DB.st_created_at);
  if (rc != SQLITE_ROW) {
    sqlite3_reset(G_DB.st_created_at);
    return -1;
  }

  struct ob o;
  ob_init(&o, out_buf, cap);
  ob_lit(&o, "{\"post\":");
  ob_post_obj(&o, id, body, (int)body_len,
              sqlite3_column_text(G_DB.st_created_at, 0), sqlite3_column_bytes(G_DB.st_created_at, 0),
              author, (int)author_len, 0);
  ob_char(&o, '}');
  sqlite3_reset(G_DB.st_created_at);
  if (o.err) return -1;
  *out_len = o.n;
  return 0;
}

int ac_db_like(int64_t user_id, int64_t post_id) {
  // First check if post exists
  if (G_DB.bt.open) {
    int exists = bt_post_exists(&G_DB.bt, post_id);
    if (exists == 1) return 0; // 404 not found
  } else {
    sqlite3_bind_int64(G_DB.st_post_exists, 1, post_id);
    int exists_rc = sqlite3_step(G_DB.st_post_exists);
    sqlite3_reset(G_DB.st_post_exists);
    if (exists_rc != SQLITE_ROW) return 0; // 404 not found
  }

  sqlite3_bind_int64(G_DB.st_ins_like, 1, user_id);
  sqlite3_bind_int64(G_DB.st_ins_like, 2, post_id);
  int rc = sqlite3_step(G_DB.st_ins_like);
  sqlite3_reset(G_DB.st_ins_like);
  if (rc != SQLITE_DONE) return -1;

  if (sqlite3_changes(G_DB.c) == 1) {
    G_DB.wrote = 1;
    return 1; // liked (201)
  }
  return 2; // already liked (200)
}
