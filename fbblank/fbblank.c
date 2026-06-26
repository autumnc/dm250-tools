/* fbblank.c — framebuffer idle blanking daemon, foreground for runit */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <dirent.h>
#include <sys/wait.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <linux/input-event-codes.h>
#include <sys/ioctl.h>

#define MAX_INPUTS 16

static volatile sig_atomic_t g_running = 1;
static pid_t g_child_pid = 0;

/* minimal write helpers — avoid pulling in printf machinery */

static void eputs(const char *s)
{
	const char *p = s;
	while (*p) p++;
	write(STDERR_FILENO, s, (size_t)(p - s));
}

static void eputs_i(int n)
{
	char b[12], t[12];
	int i = 0, j = 0;
	if (n < 0) { b[i++] = '-'; n = -n; }
	do { t[j++] = '0' + (char)(n % 10); n /= 10; } while (n);
	while (j) b[i++] = t[--j];
	write(STDERR_FILENO, b, (size_t)i);
}

static void eperr(const char *s)
{
	eputs(s);
	eputs(": ");
	eputs_i(errno);
	eputs("\n");
}

static void on_signal(int s)
{
	(void)s;
	g_running = 0;
	if (g_child_pid > 0) kill(g_child_pid, SIGTERM);
}

static int run_cmd(const char *cmd)
{
	pid_t pid = fork();
	if (pid < 0) { eperr("fork"); return -1; }
	if (pid == 0) {
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		_exit(127);
	}
	g_child_pid = pid;
	int status;
	while (waitpid(pid, &status, 0) < 0) {
		if (errno == EINTR) continue;
		eperr("waitpid");
		g_child_pid = 0;
		return -1;
	}
	g_child_pid = 0;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int is_key_device(int fd)
{
	unsigned long evbit = 0;
	if (ioctl(fd, EVIOCGBIT(0, sizeof(evbit)), &evbit) < 0) return 0;
	if (!(evbit & (1UL << EV_KEY))) return 0;

	unsigned char kb[(KEY_MAX / 8) + 1];
	memset(kb, 0, sizeof(kb));
	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(kb)), kb) < 0) return 0;

	int t[] = { KEY_ENTER, KEY_SPACE, KEY_A, KEY_LEFTCTRL };
	for (unsigned i = 0; i < sizeof(t)/sizeof(t[0]); i++) {
		int k = t[i];
		if (kb[k / 8] & (1 << (k % 8))) return 1;
	}
	return 0;
}

/* scan /dev/input/event* for keyboard devices */
static int scan_inputs(struct pollfd *pfd, int max)
{
	int n = 0;
	DIR *d = opendir("/dev/input");
	if (!d) return 0;
	struct dirent *e;
	while ((e = readdir(d)) && n < max) {
		if (strncmp(e->d_name, "event", 5) != 0) continue;
		if (e->d_name[5] < '0' || e->d_name[5] > '9') continue;
		char path[24];
		memcpy(path, "/dev/input/", 11);
		char *dst = path + 11;
		const char *src = e->d_name;
		while ((*dst++ = *src++));
		int fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0) continue;
		if (!is_key_device(fd)) { close(fd); continue; }
		pfd[n].fd = fd; pfd[n].events = POLLIN; pfd[n].revents = 0;
		n++;
	}
	closedir(d);
	return n;
}

int main(int argc, char **argv)
{
	int idle_sec = 300, sleep_sec = 0;
	const char *sleep_cmd = NULL, *fbdev = "/dev/fb0";
	int opt;
	while ((opt = getopt(argc, argv, "t:s:c:f:h")) != -1) {
		switch (opt) {
		case 't': idle_sec = atoi(optarg); break;
		case 's': sleep_sec = atoi(optarg); break;
		case 'c': sleep_cmd = optarg; break;
		case 'f': fbdev = optarg; break;
		default:
			eputs("usage: fbblank [-t idle_sec] [-s sleep_sec] [-c cmd] [-f /dev/fbN]\n");
			return opt == 'h' ? 0 : 1;
		}
	}
	if (idle_sec <= 0) { eputs("idle time must be > 0\n"); return 1; }
	if (sleep_sec > 0 && sleep_sec <= idle_sec) {
		eputs("sleep_sec ("); eputs_i(sleep_sec);
		eputs(") must be > idle_sec ("); eputs_i(idle_sec); eputs(")\n");
		return 1;
	}
	if (sleep_sec > 0 && !sleep_cmd) {
		eputs("-s requires -c <command>\n");
		return 1;
	}

	int fbfd = open(fbdev, O_RDWR);
	if (fbfd < 0) { eperr("open fb"); return 1; }

	struct pollfd pfd[MAX_INPUTS];
	int nfd = scan_inputs(pfd, MAX_INPUTS);
	if (nfd == 0) { eputs("no key input device found\n"); return 1; }

	struct sigaction sa; memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT,  &sa, NULL);

	int blanked = 0, slept = 0;
	time_t last_input = time(NULL);

	while (g_running) {
		int timeout;
		if (!blanked) {
			time_t now = time(NULL);
			long remain = (long)idle_sec - (long)(now - last_input);
			if (remain <= 0) {
				if (ioctl(fbfd, FBIOBLANK, 1) == 0) blanked = 1;
				continue;
			}
			timeout = (int)(remain * 1000);
		} else if (sleep_sec > 0 && !slept) {
			time_t now = time(NULL);
			long remain = (long)sleep_sec - (long)(now - last_input);
			if (remain <= 0) {
				eputs("fbblank: running sleep command: ");
				eputs(sleep_cmd); eputs("\n");
				int ret = run_cmd(sleep_cmd);
				if (ret != 0) {
					eputs("fbblank: sleep command failed (");
					eputs_i(ret); eputs("), retrying after ");
					eputs_i(sleep_sec - idle_sec); eputs(" s\n");
					last_input = time(NULL);
					remain = sleep_sec;
					timeout = (int)(remain * 1000);
					goto do_poll;
				}
				slept = 1;
				/* After resume, input/fb FDs may be stale. Reinit. */
				for (int i = 0; i < nfd; i++) close(pfd[i].fd);
				close(fbfd);
				fbfd = open(fbdev, O_RDWR);
				if (fbfd < 0) { eperr("open fb after sleep"); break; }
				nfd = scan_inputs(pfd, MAX_INPUTS);
				if (nfd == 0) { eputs("no input after sleep\n"); break; }
				ioctl(fbfd, FBIOBLANK, 0);
				blanked = 0;
				last_input = time(NULL);
				continue;
			}
			timeout = (int)(remain * 1000);
		} else {
			timeout = -1;
		}

do_poll: {
		int r = poll(pfd, nfd, timeout);
		if (r < 0) {
			if (errno == EINTR) continue;
			eperr("poll"); break;
		}
		if (r > 0) {
			if (blanked) { ioctl(fbfd, FBIOBLANK, 0); blanked = 0; }
			slept = 0;
			last_input = time(NULL);
			for (int i = 0; i < nfd; i++) {
				if (pfd[i].revents & (POLLIN | POLLHUP)) {
					struct input_event ev;
					while (read(pfd[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {}
				}
				pfd[i].revents = 0;
			}
		}
	}
	}

	if (blanked) ioctl(fbfd, FBIOBLANK, 0);
	for (int i = 0; i < nfd; i++) close(pfd[i].fd);
	close(fbfd);
	return 0;
}
