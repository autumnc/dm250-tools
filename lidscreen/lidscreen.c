/* lidscreen.c - DM250 lid switch -> screen blank/unblank daemon.
 *
 * The clamshell lid has a hall/reed sensor on gpio20 (gpio0 RK_PC4),
 * ACTIVE_LOW: value 0 = lid closed, 1 = open. The 3.10 kernel does not
 * register it as an input device, so we watch it through sysfs gpio
 * (edge=both + poll()) and drive /dev/fb0 with FBIOBLANK.
 *
 * Blank policy: blank (FB_BLANK_POWERDOWN) whenever the lid reads closed;
 * unblank (FB_BLANK_UNBLANK) only on a fresh open *transition*. The periodic
 * watchdog re-blanks a closed lid (guards against a missed edge) but never
 * unblanks, so we cannot fight the fbblank idle-blanker when the lid is open.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#define GPIO_DIR "/sys/class/gpio"
#define GPIONUM  20
#define FBDEV    "/dev/fb0"

static int fb = -1;

static void blank_fb(int blank)
{
    int v = blank ? FB_BLANK_POWERDOWN : FB_BLANK_UNBLANK;
    if (ioctl(fb, FBIOBLANK, v) < 0)
        fprintf(stderr, "lidscreen: FBIOBLANK=%d failed: %s\n", v, strerror(errno));
    else
        fprintf(stderr, "lidscreen: blank=%d\n", blank);
}

static int sysfs_write(const char *path, const char *val)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "lidscreen: open %s: %s\n", path, strerror(errno));
        return -1;
    }
    if (write(fd, val, strlen(val)) < 0) {
        fprintf(stderr, "lidscreen: write %s <- %s: %s\n", path, val, strerror(errno));
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int read_gpio_val(int fd)
{
    char b[8] = {0};
    if (lseek(fd, 0, SEEK_SET) < 0) return -1;
    if (read(fd, b, sizeof(b) - 1) < 1) return -1;
    return atoi(b);
}

int main(int argc, char **argv)
{
    int gpio = GPIONUM;
    if (argc > 1) gpio = atoi(argv[1]);

    char base[128], path[160];

    /* Boot race: udev may not have gpio sysfs up yet when runit starts us.
     * Retry export until the value node exists (~15s cap). */
    char num[8];
    snprintf(num, sizeof num, "%d", gpio);
    snprintf(path, sizeof path, GPIO_DIR "/gpio%d/value", gpio);
    int up = 0;
    for (int i = 0; i < 30; i++) {
        if (access(path, R_OK) == 0) { up = 1; break; }
        sysfs_write(GPIO_DIR "/export", num);
        usleep(500000);
    }
    if (!up) {
        fprintf(stderr, "lidscreen: gpio%d never became available, giving up\n", gpio);
        return 1;
    }

    snprintf(base, sizeof base, GPIO_DIR "/gpio%d", gpio);
    snprintf(path, sizeof path, "%s/direction", base);
    sysfs_write(path, "in");
    snprintf(path, sizeof path, "%s/edge", base);
    if (sysfs_write(path, "both") < 0) {
        fprintf(stderr, "lidscreen: gpio%d no 'both' edge support?\n", gpio);
    }

    snprintf(path, sizeof path, "%s/value", base);
    int vfd;
    for (int i = 0; i < 30; i++) {
        vfd = open(path, O_RDONLY);
        if (vfd >= 0) break;
        usleep(500000);
    }
    if (vfd < 0) {
        fprintf(stderr, "lidscreen: open %s: %s\n", path, strerror(errno));
        return 1;
    }

    for (int i = 0; i < 30; i++) {
        fb = open(FBDEV, O_RDWR);
        if (fb >= 0) break;
        usleep(500000);
    }
    if (fb < 0) {
        fprintf(stderr, "lidscreen: open %s: %s\n", FBDEV, strerror(errno));
        return 1;
    }

    int val = read_gpio_val(vfd);
    int prev = val;
    fprintf(stderr, "lidscreen: gpio%d initial value=%d (0=closed,1=open)\n", gpio, val);
    if (val == 0)
        blank_fb(1); /* boot with lid closed: blank now */

    struct pollfd pfd;
    pfd.fd = vfd;
    pfd.events = POLLPRI | POLLERR;

    for (;;) {
        /* 30s watchdog: re-blank if the lid is closed but we missed an edge. */
        int r = poll(&pfd, 1, 30000);
        if (r < 0) {
            if (errno == EINTR) continue;
            perror("lidscreen: poll");
            break;
        }
        val = read_gpio_val(vfd);
        if (val < 0) {
            fprintf(stderr, "lidscreen: read gpio failed: %s\n", strerror(errno));
            usleep(500000);
            continue;
        }
        if (r > 0) {
            /* genuine edge. debounce: settle then confirm. */
            usleep(150000);
            val = read_gpio_val(vfd);
            if (val == prev) { /* bounce, ignore */
                fprintf(stderr, "lidscreen: bounce (still %d), ignore\n", val);
                continue;
            }
            prev = val;
            fprintf(stderr, "lidscreen: lid %s\n", val ? "OPEN" : "CLOSED");
            if (val == 0) blank_fb(1);
            else          blank_fb(0);
        } else {
            /* watchdog tick: closed -> blank only, never unblank. */
            if (val == 0 && prev != 0) {
                prev = 0;
                fprintf(stderr, "lidscreen: watchdog sees CLOSED, blank\n");
                blank_fb(1);
            }
        }
    }
    return 0;
}
