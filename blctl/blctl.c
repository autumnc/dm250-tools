#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <poll.h>
#include <errno.h>
#include <time.h>

#define BL_PATH  "/sys/class/backlight/rk28_bl/brightness"
#define BL_MIN   30
#define BL_MAX   150
#define STEP     5
#define IDLE_SEC 3
#define BAR_W    20

static struct termios save;

static void cleanup(void)
{
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &save);
    printf("\033[?25h\n");
}

static int read_val(void)
{
    int fd = open(BL_PATH, O_RDONLY);
    if (fd < 0) return -1;
    char buf[16];
    int n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    return atoi(buf);
}

static void write_val(int v)
{
    if (v < BL_MIN) v = BL_MIN;
    if (v > BL_MAX) v = BL_MAX;
    int fd = open(BL_PATH, O_WRONLY);
    if (fd < 0) return;
    char buf[16];
    int n = snprintf(buf, sizeof(buf), "%d\n", v);
    write(fd, buf, n);
    close(fd);
}

static int to_pct(int v)
{
    return (v - BL_MIN) * 100 / (BL_MAX - BL_MIN);
}

static int from_pct(int p)
{
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    return BL_MIN + (p * (BL_MAX - BL_MIN) + 50) / 100;
}

static void draw(int val)
{
    int p = to_pct(val);
    int filled = p * BAR_W / 100;
    printf("\r\033[K☀ [");
    for (int i = 0; i < BAR_W; i++)
        putchar(i < filled ? '#' : '-');
    printf("] %3d%% (%d)", p, val);
    fflush(stdout);
}

int main(void)
{
    int cur = read_val();
    if (cur < BL_MIN || cur > BL_MAX) {
        fprintf(stderr, "Cannot read backlight (value=%d)\n", cur);
        return 1;
    }
    int val = cur;

    tcgetattr(STDIN_FILENO, &save);
    atexit(cleanup);
    struct termios raw = save;
    raw.c_lflag &= ~(ECHO | ICANON);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);

    printf("\033[?25l");
    draw(val);

    time_t last = time(NULL);

    for (;;) {
        time_t now = time(NULL);
        int rem = IDLE_SEC - (int)(now - last);
        if (rem <= 0) break;

        struct pollfd pfd = {STDIN_FILENO, POLLIN, 0};
        int r = poll(&pfd, 1, rem * 1000);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (r == 0) break;

        char c;
        if (read(STDIN_FILENO, &c, 1) != 1) break;
        last = time(NULL);

        if (c == '\x1b') {
            struct pollfd pfd2 = {STDIN_FILENO, POLLIN, 0};
            if (poll(&pfd2, 1, 150) > 0) {
                char c2;
                if (read(STDIN_FILENO, &c2, 1) == 1 && (c2 == '[' || c2 == 'O')) {
                    char rest[4] = {0};
                    int nr = 0;
                    while (nr < 3) {
                        struct pollfd pfd3 = {STDIN_FILENO, POLLIN, 0};
                        if (poll(&pfd3, 1, 150) <= 0) break;
                        if (read(STDIN_FILENO, &rest[nr], 1) != 1) break;
                        nr++;
                        if (rest[nr - 1] == '~' ||
                            (rest[nr - 1] >= 'A' && rest[nr - 1] <= 'Z'))
                            break;
                    }
                    if (c2 == '[' && nr >= 2 &&
                        rest[0] == '5' && rest[1] == '~') {        /* PageUp: dim */
                        val = from_pct(to_pct(val) - STEP);
                        write_val(val);
                        draw(val);
                    } else if (c2 == '[' && nr >= 2 &&
                               rest[0] == '6' && rest[1] == '~') { /* PageDown: brighten */
                        val = from_pct(to_pct(val) + STEP);
                        write_val(val);
                        draw(val);
                    }
                }
            } else {
                break; /* plain Esc */
            }
        }
    }
    return 0;
}
