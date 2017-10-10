#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdarg.h>
#include <string.h>
#include <getopt.h>
#include <errno.h>
#include <search.h>
#include <sys/param.h>
#include <sys/ucred.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/jail.h>
#include <jail.h>
#include <assert.h>
#include <sys/queue.h>
#include <limits.h> /* PATH_MAX */

// cc mounted.c (-g) -o mounted -ljail

#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define STR_LEN(str)      (ARRAY_SIZE(str) - 1)
#define STR_SIZE(str)     (ARRAY_SIZE(str))

# ifndef MAX
#  define MAX(a, b) ((a) > (b) ? (a) : (b))
# endif /* !MAX */

#define error(msg, ...) \
    do { \
        fprintf(stderr, "[%d] " msg "\n", __LINE__, ## __VA_ARGS__); \
        exit(EXIT_FAILURE); \
    } while (0);

#ifdef DEBUG
# define debug(msg, ...) \
        do { \
            fprintf(stderr, "[DEBUG] [%d] " msg "\n", __LINE__, ## __VA_ARGS__); \
        } while (0);
#else
# define debug(msg, ...) \
    /* NOP */
#endif /* DEBUG */

#ifndef EUSAGE
# define EUSAGE -2
#endif /* !EUSAGE */

typedef enum {
    VISITED,
    NOT_VISITED,
    IN_PROGRESS,
} state_t;

typedef struct node_t {
    state_t visited;
    const char *name;
    struct statfs *mntbufp;
    TAILQ_HEAD(foo, node_t) head;
    TAILQ_ENTRY(node_t) children;
} node_t;

static bool starts_with(const char *string, const char *prefix)
{
    size_t prefix_len;

    assert(NULL != string);
    assert(NULL != prefix);

    prefix_len = strlen(prefix);

    return prefix_len <= strlen(string) && 0 == strncmp(string, prefix, prefix_len);
}

static void strip(char *path, size_t path_size, const char *fallback)
{
    char *ls; // last slash

    if (NULL == (ls = strrchr(path, '/'))) {
        if (strlcpy(path, fallback, path_size) >= path_size) {
            error("strlcpy: buffer overflow");
        }
    } else {
        *ls = '\0';
    }
}

static void visit_node(node_t *node, struct statfs *sorted, size_t *sorted_len)
{
    node_t *child;

    node->visited = IN_PROGRESS;
    if (!TAILQ_EMPTY(&node->head)) {    
        TAILQ_FOREACH(child, &node->head, children) {
            if (NOT_VISITED == child->visited) {
                visit_node(child, sorted, sorted_len);
            }
        }
    }
    node->visited = VISITED;
    if (NULL != node->mntbufp) {
        memcpy(&sorted[*sorted_len], node->mntbufp, sizeof(*sorted));
        ++*sorted_len;
    }
}

static struct statfs *sort_nodes(node_t *root, size_t nodes_size)
{
    size_t sorted_len;
    struct statfs *sorted;

    sorted_len = 0;
    if (NULL == (sorted = calloc(nodes_size, sizeof(*sorted)))) {
        error("calloc");
    }
    visit_node(root, sorted, &sorted_len);

    return sorted;
}

static void print_nodes(node_t *parent, int level)
{
    node_t *child;

    fprintf(stderr, "%*s%s%s\n", MAX(0, level - 1), "", 0 == level ? "" : "↳", parent->name);
    if (!TAILQ_EMPTY(&parent->head)) {
//         printf("%*s<%s> %s\n", level * 4, "", parent->name, NULL == parent->mntbufp ? "NULL" : parent->mntbufp->f_mntonname);
        TAILQ_FOREACH(child, &parent->head, children) {
            print_nodes(child, level + 1);
        }
//         printf("%*s</%s> %s\n", level * 4, "", parent->name, NULL == parent->mntbufp ? "NULL" : parent->mntbufp->f_mntonname);
    } else {
//         printf("%*s%s %s\n", level * 4, "", parent->name, NULL == parent->mntbufp ? "NULL" : parent->mntbufp->f_mntonname);
    }
}

static node_t *init_and_add_node_to_ht(struct hsearch_data *ht, node_t *node, struct statfs *mntbufp, const char *path)
{
    ENTRY item, *itemp;

    item.data = node;
    node->mntbufp = mntbufp;
    node->visited = NOT_VISITED;
    node->name = item.key = (char *) /*strdup*/(path);
    node->head = (struct foo) TAILQ_HEAD_INITIALIZER(node->head);
    TAILQ_INIT(&node->head);
    if (1 != hsearch_r(item, ENTER, &itemp, ht)/* || NULL != itemp*/) {
        error("hsearch_r: %s", path);
    }

    return node;
}

size_t get_mountpoints_in(const char *path, struct statfs **sorted)
{
    size_t node_len;
    int i, mntbufp_len;
    node_t *nodes, *root;
    struct hsearch_data ht;
    struct statfs *mntbufp;

    node_len = 0;
    if (0 == (mntbufp_len = getmntinfo(&mntbufp, MNT_WAIT))) { // MNT_NOWAIT?
        error("getmntinfo");
    }
    if (0 == hcreate_r((size_t) mntbufp_len, &ht)) {
        error("hcreate_r");
    }
    // "+ 1" for our potential virtual root
    if (NULL == (nodes = calloc(mntbufp_len + 1, sizeof(*nodes)))) {
        error("calloc");
    }
    // create a virtual root, path may not be a mountpoint itself
    root = init_and_add_node_to_ht(&ht, &nodes[node_len++], NULL, path);
    for (i = 0; i < mntbufp_len; i++) {
        // the given path is a real mountpoint, update its info
        if (0 == strcmp(mntbufp[i].f_mntonname, path)) {
            root->mntbufp = &mntbufp[i];
        } else if (starts_with(mntbufp[i].f_mntonname, path)) {
            init_and_add_node_to_ht(&ht, &nodes[node_len++], &mntbufp[i], mntbufp[i].f_mntonname);
        }
    }
    for (i = 0; i < node_len; i++) {
        if (NULL != nodes[i].mntbufp) {
            bool found;
            ENTRY item;
            char buffer[PATH_MAX];

            found = false;
            item.data = 0;
            item.key = (char *) buffer;
            if (strlcpy(buffer, nodes[i].mntbufp->f_mntonname, STR_SIZE(buffer)) >= STR_SIZE(buffer)) {
                error("strlcpy: buffer overflow");
            }
            while (0 != strcmp(path, buffer) && !found) {
                ENTRY *itemp;

                strip(buffer, STR_SIZE(buffer), path);
                if  (1 == hsearch_r(item, FIND, &itemp, &ht)) {
                    node_t *node;

                    found = true;
                    node = (node_t *) itemp->data;
                    debug("ADD %s => %s", nodes[i].mntbufp->f_mntonname, node->name);
                    TAILQ_INSERT_HEAD(&node->head, &nodes[i], children);
                }
            }
        }
    }
#ifdef DEBUG
    print_nodes(root, 0);
#endif /* DEBUG */
    node_len -= (NULL == root->mntbufp);
    *sorted = sort_nodes(root, node_len);
    hdestroy_r(&ht);
    free(mntbufp);
    free(nodes);

    return node_len;
}

extern char *__progname;

static char optstr[] = "j:p:rv";

static struct option long_options[] = {
    { "jail",    required_argument, NULL, 'j' },
    { "path",    required_argument, NULL, 'p' },
    { "reverse", no_argument,       NULL, 'r' },
    { "verbose", no_argument,       NULL, 'v' },
    { NULL,      no_argument,       NULL, 0   }
};

static void usage(void)
{
    fprintf(
        stderr,
        "usage: %s [-%s]\n",
        __progname,
        optstr
    );
    exit(EUSAGE);
}

int main(int argc, char **argv)
{
    int o;
    char *path;
    size_t mntbufp_len;
    struct statfs *mntbufp;
    bool pFlag, jFlag, rFlag;

    path = NULL;
    jFlag = pFlag = rFlag = false;
    while (-1 != (o = getopt_long(argc, argv, optstr, long_options, NULL))) {
        switch (o) {
            // -p flag is intended to unmount remaining file systems when jail stop process fails
            case 'p':
                pFlag = true;
                path = strdup(optarg);
                break;
            case 'j':
            {
                int ret;
                const char *errstr;
                struct jailparam params[2];

                jFlag = true;
                strtonum(optarg, 1, LLONG_MAX, &errstr);
                if (NULL == errstr) {
                    ret = jailparam_init(&params[0], "jid");
                } else {
                    ret = jailparam_init(&params[0], "name");
                }
                if (0 != ret) {
                    error("jailparam_init: %s", jail_errmsg);
                }
                if (0 != jailparam_import(&params[0], optarg)) {
                    error("jailparam_import: %s", jail_errmsg);
                }
                if (0 != jailparam_init(&params[1], "path")) {
                    error("jailparam_init: %s", jail_errmsg);
                }
                if (-1 == jailparam_get(params, ARRAY_SIZE(params), 0)) {
                    error("jailparam_get: %s", jail_errmsg);
                }
                if (NULL == (path = jailparam_export(&params[1]))) {
                    error("jailparam_export: %s", jail_errmsg);
                }
                jailparam_free(params, ARRAY_SIZE(params));
                break;
            }
            case 'r':
                rFlag = true;
                break;
            case 'v':
                break;
            case 'h':
            default:
                usage();
                break;
        }
    }
    if (pFlag && jFlag) {
        error("-p and -j option are mutually exclusive");
    }
    if (NULL == path) {
        path = strdup("/");
    }
    argc -= optind;
    argv += optind;
    if (0 != argc) {
        usage();
    }
    if (-1 == (mntbufp_len = get_mountpoints_in(path, &mntbufp))) {
        error("get_mountpoints_in");
    } else {
        int i;

        if (rFlag) {
            for (i = mntbufp_len - 1; i >= 0; i--) {
                printf("%s\n", mntbufp[i].f_mntonname);
            }
        } else {
            for (i = 0; i < mntbufp_len; i++) {
                printf("%s\n", mntbufp[i].f_mntonname);
            }
        }
        free(mntbufp);
    }
    free(path);

    return EXIT_SUCCESS;
}
