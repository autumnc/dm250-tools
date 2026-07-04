#include <locale.h>
#include <ncurses.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FBTERM_MODRC "/root/.fbterm-modrc"
#define PROFILE "/root/.profile"
#define AICHAT_CONFIG "/root/.config/aichat/config.toml"
#define WIFI_TUI "/root/bin/wifi-tui"

#define TMP_FBTERM "/tmp/.fbterm-modrc.tmp"
#define TMP_PROFILE "/tmp/.profile.tmp"
#define TMP_AICHAT "/tmp/.aichat-config.tmp"

#define MAX_LINES 200
#define MAX_LINE_LEN 512
#define MAX_KEY_LEN 256

/* ---------- font presets ---------- */
static const char *main_font_presets[][3] = {
    {"font-names=Go\\-Song2 Propo:style=Regular",
     "font-names-bold=Go\\-Song2:style=Bold",
     "Go Mono+宋二"},
    {"font-names=FZFW ZhuZi MinchoS:style=Regular",
     "font-names-bold=FZFW ZhuZi MinchoS:style=Bold",
     "Xenon+书局宋"},
    {"font-names=Terminus Song:style=Regular",
     "font-names-bold=Terminus Hei:style=Bold",
     "Terminus+像素宋"},
};

static const char *italic_font_presets[][2] = {
    {"font-names-italic=MapleXiuKai:style=Italic", "Maple italic+秀楷"},
    {"font-names-italic=HYQTS:style=Italic",       "Radon+全唐诗楷"},
};

/* ---------- shared ---------- */
static int term_w, term_h;

static void copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "r");
    if (!in) return;
    FILE *out = fopen(dst, "w");
    if (!out) { fclose(in); return; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
        fwrite(buf, 1, n, out);
    fclose(in);
    fclose(out);
}

/* ---------- ncurses helpers ---------- */
static void init_colors(void) {
    use_default_colors();
    start_color();
    init_pair(1, COLOR_WHITE,  COLOR_CYAN);   /* title bar, teal bg */
    init_pair(2, COLOR_BLACK,  COLOR_CYAN);   /* selected item */
    init_pair(3, COLOR_WHITE,  -1);           /* normal item, terminal bg */
    init_pair(4, COLOR_CYAN,   -1);           /* dim text / help, terminal bg */
    init_pair(5, COLOR_RED,    -1);           /* error, terminal bg */
    init_pair(6, COLOR_YELLOW, -1);           /* warning / dialog border */
    init_pair(7, COLOR_GREEN,  -1);           /* success, terminal bg */
}

/* force full window redraw — fbterm needs this to avoid text residue */
static void frefresh(WINDOW *w) {
    redrawwin(w);
    wrefresh(w);
}

static WINDOW *create_centered_win(int height, int width) {
    int y = (term_h - height) / 2;
    int x = (term_w - width) / 2;
    WINDOW *w = newwin(height, width, y, x);
    keypad(w, TRUE);
    return w;
}

static void draw_title(WINDOW *w, int width, const char *title) {
    wattron(w, A_BOLD);
    mvwprintw(w, 0, (width - (int)strlen(title)) / 2, "%s", title);
    wattroff(w, A_BOLD);
}

/* ---------- generic menu ---------- */
typedef struct { const char *label; } MenuItem;

/* returns 0-based index of selected item, or -1 on cancel/back */
static int menu_select(const char *title, const char **items, int count,
                       int show_numbers, const char *status_text) {
    int height = count + 4;
    /* width: just enough to hold the longest line + 4-column margin */
    int width = (int)strlen(status_text ? status_text : "") + 4;
    {   int tw = (int)strlen(title) + 4;
        if (tw > width) width = tw; }
    for (int i = 0; i < count; i++) {
        int w = (int)strlen(items[i]) + 4;
        if (show_numbers) w += 4;
        if (w > width) width = w;
    }
    if (width > term_w - 4) width = term_w - 4;

    clearok(curscr, TRUE);
    erase();
    refresh();

    WINDOW *w = create_centered_win(height, width);
    if (!w) return -1;

    int sel = 0;
    for (;;) {
        werase(w);
        box(w, 0, 0);
        draw_title(w, width, title);

        for (int i = 0; i < count; i++) {
            if (i == sel) wattron(w, COLOR_PAIR(2));
            else wattron(w, COLOR_PAIR(3));

            mvwaddch(w, i + 2, 1, ' ');
            if (show_numbers) mvwprintw(w, i + 2, 2, "%d) ", i + 1);
            mvwprintw(w, i + 2, show_numbers ? 6 : 2, "%s", items[i]);
            mvwaddch(w, i + 2, width - 2, ' ');

            if (i == sel) wattroff(w, COLOR_PAIR(2));
            else wattroff(w, COLOR_PAIR(3));
        }

        if (status_text) {
            wattron(w, COLOR_PAIR(4));
            mvwprintw(w, height - 2, 2, "%s", status_text);
            wattroff(w, COLOR_PAIR(4));
        }

        frefresh(w);

        int ch = wgetch(w);
        switch (ch) {
        case KEY_UP:    case 'k': sel = (sel - 1 + count) % count; break;
        case KEY_DOWN:  case 'j': sel = (sel + 1) % count; break;
        case '0': case '1': case '2': case '3': case '4':
        case '5': case '6': case '7': case '8': case '9':
            if (show_numbers) {
                int n = ch - '0';
                if (n > 0 && n <= count) { delwin(w); return n - 1; }
                if (n == 0) { delwin(w); return count - 1; }
            }
            break;
        case KEY_ENTER: case '\n': case '\r': case ' ':
            delwin(w); return sel;
        case 27: case 'q': /* ESC or q */
            delwin(w); return -1;
        }
    }
}

/* ---------- confirmation dialog ---------- */
/* Count \n in msg and print each line individually */
static int print_multiline(WINDOW *w, int y, int x, const char *msg) {
    char buf[512];
    snprintf(buf, sizeof(buf), "%s", msg);
    int line = y;
    char *save, *tok = strtok_r(buf, "\n", &save);
    while (tok) {
        mvwprintw(w, line++, x, "%s", tok);
        tok = strtok_r(NULL, "\n", &save);
    }
    return line; /* next available row */
}

static int confirm_dialog(const char *title, const char *msg) {
    /* measure width: longest line in msg */
    int maxw = 0, line_count = 1;
    for (const char *p = msg; *p; p++) {
        if (*p == '\n') line_count++;
    }
    {
        char buf[512];
        snprintf(buf, sizeof(buf), "%s", msg);
        char *save, *tok = strtok_r(buf, "\n", &save);
        while (tok) {
            int w = (int)strlen(tok);
            if (w > maxw) maxw = w;
            tok = strtok_r(NULL, "\n", &save);
        }
    }
    int width = maxw + 10;
    if (width < 40) width = 40;
    if (width > term_w - 4) width = term_w - 4;
    int height = line_count + 7; /* title + msg lines + buttons + hint */

    /* clean screen first — caller may have left stale window content */
    clearok(curscr, TRUE);
    erase();
    refresh();

    WINDOW *w = create_centered_win(height, width);
    if (!w) return 0;

    int sel = 1; /* default to No */
    const char *btns[] = {"  是 (Y)  ", "  否 (N)  "};

    for (;;) {
        werase(w);
        box(w, 0, 0);
        wattron(w, COLOR_PAIR(6));
        mvwprintw(w, 0, 2, " %s ", title);
        wattroff(w, COLOR_PAIR(6));
        print_multiline(w, 2, 2, msg);

        int btn_row = 2 + line_count + 1;
        for (int i = 0; i < 2; i++) {
            int bx = width / 2 - 8 + i * 12;
            if (i == sel) wattron(w, COLOR_PAIR(2));
            else wattron(w, COLOR_PAIR(3));
            mvwprintw(w, btn_row, bx, "%s", btns[i]);
            if (i == sel) wattroff(w, COLOR_PAIR(2));
            else wattroff(w, COLOR_PAIR(3));
        }

        wattron(w, COLOR_PAIR(4));
        mvwprintw(w, height - 2, 2, "Enter/Space 确认  Tab 切换  Esc 取消");
        wattroff(w, COLOR_PAIR(4));
        frefresh(w);

        int ch = wgetch(w);
        switch (ch) {
        case KEY_LEFT:  case KEY_UP:   sel = 0; break;
        case KEY_RIGHT: case KEY_DOWN: sel = 1; break;
        case '\t': sel = !sel; break;
        case 'y': case 'Y': delwin(w); return 1;
        case 'n': case 'N': delwin(w); return 0;
        case KEY_ENTER: case '\n': case '\r': case ' ':
            delwin(w); return (sel == 0);
        case 27: delwin(w); return 0;
        }
    }
}

/* ---------- message dialog ---------- */
static void msg_dialog(const char *title, const char *msg) {
    int maxw = 0, line_count = 1;
    for (const char *p = msg; *p; p++)
        if (*p == '\n') line_count++;
    {
        char buf[512];
        snprintf(buf, sizeof(buf), "%s", msg);
        char *save, *tok = strtok_r(buf, "\n", &save);
        while (tok) {
            int w = (int)strlen(tok);
            if (w > maxw) maxw = w;
            tok = strtok_r(NULL, "\n", &save);
        }
    }
    int width = maxw + 10;
    if (width < 36) width = 36;
    if (width > term_w - 4) width = term_w - 4;
    int height = line_count + 5;

    clearok(curscr, TRUE);
    erase();
    refresh();

    WINDOW *w = create_centered_win(height, width);
    if (!w) return;
    draw_title(w, width, title);
    print_multiline(w, 2, 2, msg);
    wattron(w, COLOR_PAIR(4));
    mvwprintw(w, height - 2, 2, "按任意键继续...");
    wattroff(w, COLOR_PAIR(4));
    frefresh(w);
    wgetch(w);
    delwin(w);
}

/* ---------- text input dialog ---------- */
static int input_dialog(const char *title, const char *prompt, char *buf, int buf_size) {
    int width = 56;
    if (width > term_w - 4) width = term_w - 4;
    clearok(curscr, TRUE);
    erase();
    refresh();
    WINDOW *w = create_centered_win(7, width);
    if (!w) return 0;

    buf[0] = '\0';
    int pos = 0, len = 0;
    curs_set(1);

    for (;;) {
        werase(w);
        box(w, 0, 0);
        draw_title(w, width, title);
        mvwprintw(w, 2, 2, "%s", prompt);

        wattron(w, COLOR_PAIR(2));
        for (int i = 0; i < width - 6; i++)
            mvwaddch(w, 3, 2 + i, ' ');
        mvwprintw(w, 3, 3, "%s", buf);
        wattroff(w, COLOR_PAIR(2));

        wattron(w, COLOR_PAIR(4));
        mvwprintw(w, 5, 2, "Enter 确认  Esc 取消");
        wattroff(w, COLOR_PAIR(4));

        wmove(w, 3, 3 + pos);
        frefresh(w);

        int ch = wgetch(w);
        switch (ch) {
        case KEY_ENTER: case '\n': case '\r':
            curs_set(0);
            delwin(w);
            return 1;
        case 27:
            curs_set(0);
            delwin(w);
            return 0;
        case KEY_BACKSPACE: case 127: case '\b':
            if (pos > 0) {
                memmove(buf + pos - 1, buf + pos, len - pos + 1);
                pos--; len--;
            }
            break;
        case KEY_LEFT:
            if (pos > 0) pos--;
            break;
        case KEY_RIGHT:
            if (pos < len) pos++;
            break;
        case KEY_HOME:
            pos = 0;
            break;
        case KEY_END:
            pos = len;
            break;
        default:
            if (ch >= 32 && ch < 127 && len < buf_size - 1) {
                memmove(buf + pos + 1, buf + pos, len - pos + 1);
                buf[pos++] = (char)ch;
                len++;
            }
            break;
        }
    }
}

/* ---------- fbterm-modrc handling ---------- */
typedef struct { char *lines[MAX_LINES]; int count; } FileContent;

static FileContent *read_file(const char *path) {
    FileContent *fc = calloc(1, sizeof(FileContent));
    if (!fc) return NULL;
    FILE *f = fopen(path, "r");
    if (!f) { free(fc); return NULL; }
    char buf[MAX_LINE_LEN];
    while (fc->count < MAX_LINES && fgets(buf, sizeof(buf), f)) {
        size_t len = strlen(buf);
        if (len > 0 && buf[len - 1] == '\n') buf[len - 1] = '\0';
        fc->lines[fc->count] = strdup(buf);
        fc->count++;
    }
    fclose(f);
    return fc;
}

static void free_file_content(FileContent *fc) {
    if (!fc) return;
    for (int i = 0; i < fc->count; i++) free(fc->lines[i]);
    free(fc);
}

static void write_file(FileContent *fc, const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    for (int i = 0; i < fc->count; i++) fprintf(f, "%s\n", fc->lines[i]);
    fclose(f);
}

/* Check if line matches a key (after stripping leading # and whitespace).
   key_with_eq is like "font-names=".  Ensures font-names= doesn't claim
   font-names-bold= or font-names-italic= via prefix matching. */
static int line_matches_key(const char *line, const char *key) {
    const char *p = line;
    while (*p == '#' || *p == ' ' || *p == '\t') p++;
    size_t klen = strlen(key);
    if (strncmp(p, key, klen) != 0) return 0;
    if (p[klen] >= 'a' && p[klen] <= 'z') return 0;
    if (p[klen] == '-') return 0;
    return 1;
}

static void set_fbterm_key(FileContent *fc, const char *key, const char *val) {
    /* comment all matching lines */
    for (int i = 0; i < fc->count; i++) {
        if (line_matches_key(fc->lines[i], key)) {
            if (fc->lines[i][0] != '#') {
                char *nl = malloc(strlen(fc->lines[i]) + 2);
                sprintf(nl, "#%s", fc->lines[i]);
                free(fc->lines[i]);
                fc->lines[i] = nl;
            }
        }
    }
    /* uncomment the one with the desired value */
    for (int i = 0; i < fc->count; i++) {
        const char *p = fc->lines[i];
        while (*p == '#') p++;
        if (strncmp(p, val, strlen(val)) == 0 && fc->lines[i][0] == '#') {
            char *nl = strdup(fc->lines[i] + 1);
            free(fc->lines[i]);
            fc->lines[i] = nl;
            return;
        }
    }
    /* append new */
    if (fc->count < MAX_LINES)
        fc->lines[fc->count++] = strdup(val);
}

/* ---------- font settings ---------- */
static void show_font_info(WINDOW *w, int y, int win_width) {
    FileContent *fc = read_file(FBTERM_MODRC);
    if (!fc) return;
    wattron(w, COLOR_PAIR(4));
    int row = y;
    /* "  当前: " prefix = 8 visual cols from col 2; right margin = 2 cols;
       available for value = win_width - 2 (left offset) - 8 (prefix) - 2 (margin) */
    int maxval = win_width - 12;
    if (maxval < 8) maxval = 8;
    for (int i = 0; i < fc->count && row < term_h - 2; i++) {
        const char *p = fc->lines[i];
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '#') continue;
        if (strncmp(p, "font-names=", 11) == 0 ||
            strncmp(p, "font-names-bold=", 16) == 0 ||
            strncmp(p, "font-names-italic=", 18) == 0) {
            int vlen = (int)strlen(p);
            if (vlen > maxval)
                mvwprintw(w, row++, 2, "  当前: %.*s..", maxval - 2, p);
            else
                mvwprintw(w, row++, 2, "  当前: %s", p);
        }
    }
    wattroff(w, COLOR_PAIR(4));
    free_file_content(fc);
}

static void main_font_menu(void) {
    const char *items[] = {
        "Go Mono+宋二",
        "Xenon+书局宋",
        "Terminus+像素宋",
    };
    int h = 10, w = 56;
    clearok(curscr, TRUE);
    erase();
    refresh();
    WINDOW *win = create_centered_win(h, w);
    if (!win) return;
    int sel = 0;
    for (;;) {
        werase(win);
        box(win, 0, 0);
        draw_title(win, w, " 主字体设置 ");
        show_font_info(win, 1, w);

        for (int i = 0; i < 3; i++) {
            if (i == sel) wattron(win, COLOR_PAIR(2));
            else wattron(win, COLOR_PAIR(3));
            mvwprintw(win, i + 5, 3, "  %s  ", items[i]);
            if (i == sel) wattroff(win, COLOR_PAIR(2));
            else wattroff(win, COLOR_PAIR(3));
        }
        wattron(win, COLOR_PAIR(4));
        mvwprintw(win, h - 2, 2, "↑↓ 选择  Enter 确认  Esc 返回");
        wattroff(win, COLOR_PAIR(4));
        frefresh(win);

        int ch = wgetch(win);
        switch (ch) {
        case KEY_UP:    case 'k': sel = (sel - 1 + 3) % 3; break;
        case KEY_DOWN:  case 'j': sel = (sel + 1) % 3; break;
        case KEY_ENTER: case '\n': case '\r': case ' ': {
            FileContent *fc = read_file(FBTERM_MODRC);
            if (!fc) { msg_dialog("错误", "无法读取 fbterm-modrc"); break; }
            set_fbterm_key(fc, "font-names=", main_font_presets[sel][0]);
            set_fbterm_key(fc, "font-names-bold=", main_font_presets[sel][1]);
            write_file(fc, TMP_FBTERM);
            free_file_content(fc);
            delwin(win);
            if (confirm_dialog("确认", "应用字体设置?\n修改完成后注销重新登录起效。")) {
                copy_file(TMP_FBTERM, FBTERM_MODRC);
                msg_dialog("完成", "字体设置已应用。\n修改完成后注销重新登录起效。");
            }
            unlink(TMP_FBTERM);
            return;
        }
        case 27: case 'q': delwin(win); return;
        }
    }
}

static void italic_font_menu(void) {
    const char *items[] = {
        "Maple italic+秀楷",
        "Radon+全唐诗楷",
    };
    int h = 9, w = 56;
    clearok(curscr, TRUE);
    erase();
    refresh();
    WINDOW *win = create_centered_win(h, w);
    if (!win) return;
    int sel = 0;
    for (;;) {
        werase(win);
        box(win, 0, 0);
        draw_title(win, w, " 斜体设置 ");
        show_font_info(win, 1, w);

        for (int i = 0; i < 2; i++) {
            if (i == sel) wattron(win, COLOR_PAIR(2));
            else wattron(win, COLOR_PAIR(3));
            mvwprintw(win, i + 5, 3, "  %s  ", items[i]);
            if (i == sel) wattroff(win, COLOR_PAIR(2));
            else wattroff(win, COLOR_PAIR(3));
        }
        wattron(win, COLOR_PAIR(4));
        mvwprintw(win, h - 2, 2, "↑↓ 选择  Enter 确认  Esc 返回");
        wattroff(win, COLOR_PAIR(4));
        frefresh(win);

        int ch = wgetch(win);
        switch (ch) {
        case KEY_UP:    case 'k': sel = (sel - 1 + 2) % 2; break;
        case KEY_DOWN:  case 'j': sel = (sel + 1) % 2; break;
        case KEY_ENTER: case '\n': case '\r': case ' ': {
            FileContent *fc = read_file(FBTERM_MODRC);
            if (!fc) { msg_dialog("错误", "无法读取 fbterm-modrc"); break; }
            set_fbterm_key(fc, "font-names-italic=", italic_font_presets[sel][0]);
            write_file(fc, TMP_FBTERM);
            free_file_content(fc);
            delwin(win);
            if (confirm_dialog("确认", "应用斜体设置?\n修改完成后注销重新登录起效。")) {
                copy_file(TMP_FBTERM, FBTERM_MODRC);
                msg_dialog("完成", "斜体设置已应用。\n修改完成后注销重新登录起效。");
            }
            unlink(TMP_FBTERM);
            return;
        }
        case 27: case 'q': delwin(win); return;
        }
    }
}

static void font_settings_menu(void) {
    const char *items[] = {"主字体设置", "斜体设置"};
    for (;;) {
        int sel = menu_select(" 字体设置 ", items, 2, 1, "↑↓/jk 选择  Enter 确认  Esc 返回");
        if (sel == 0) main_font_menu();
        else if (sel == 1) italic_font_menu();
        else return;
    }
}

/* ---------- wifi ---------- */
static void wifi_settings(void) {
    endwin();
    system(WIFI_TUI);
    clearok(curscr, TRUE);
    refresh();
    msg_dialog("提示", "WiFi 配置工具已退出。");
}

/* ---------- input method ---------- */
static void im_settings(void) {
    char current[32] = "未设置";
    FILE *f = fopen(PROFILE, "r");
    if (f) {
        char buf[MAX_LINE_LEN];
        while (fgets(buf, sizeof(buf), f))
            if (strncmp(buf, "CURRENT_IM=", 11) == 0) {
                char *v = buf + 11, *e = strchr(v, '\n');
                if (e) *e = '\0';
                if (strcmp(v, "yong") == 0) snprintf(current, sizeof(current), "%s", "yong 输入法");
                else if (strcmp(v, "fcitx5") == 0) snprintf(current, sizeof(current), "%s", "fcitx5-rime");
                else snprintf(current, sizeof(current), "%.31s", v);
                break;
            }
        fclose(f);
    }

    char status[128];
    snprintf(status, sizeof(status), "当前: %s", current);
    const char *items[] = {"yong 输入法", "fcitx5-rime"};
    for (;;) {
        int sel = menu_select(" 输入法设置 ", items, 2, 1, status);
        if (sel < 0) return;

        const char *new_val = (sel == 0) ? "yong" : "fcitx5";
        FileContent *fc = read_file(PROFILE);
        if (!fc) { msg_dialog("错误", "无法读取 profile"); continue; }
        for (int i = 0; i < fc->count; i++)
            if (strncmp(fc->lines[i], "CURRENT_IM=", 11) == 0) {
                char tmp[MAX_LINE_LEN];
                snprintf(tmp, sizeof(tmp), "CURRENT_IM=%s", new_val);
                free(fc->lines[i]);
                fc->lines[i] = strdup(tmp);
            }
        write_file(fc, TMP_PROFILE);
        free_file_content(fc);

        char msg[128];
        snprintf(msg, sizeof(msg), "切换到 %s ?\n修改完成后注销重新登录起效。", items[sel]);
        if (confirm_dialog("确认", msg)) {
            copy_file(TMP_PROFILE, PROFILE);
            snprintf(current, sizeof(current), "%s", items[sel]);
            snprintf(status, sizeof(status), "当前: %s", current);
            msg_dialog("完成", "输入法已切换。\n修改完成后注销重新登录起效。");
        }
        unlink(TMP_PROFILE);
    }
}

/* ---------- AI chat ---------- */
typedef struct { char provider[MAX_KEY_LEN]; char api_key[MAX_KEY_LEN]; } ApiKeyEntry;

static const char *ai_providers[] = {"deepseek", "aliyun", "openai", "claude", "gemini"};
#define NUM_AI 5

static int load_aichat(ApiKeyEntry *e) {
    int n = 0;
    FILE *f = fopen(AICHAT_CONFIG, "r");
    if (!f) goto fill_defaults;
    char buf[MAX_LINE_LEN], sec[MAX_KEY_LEN] = "";
    while (fgets(buf, sizeof(buf), f)) {
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;
        size_t len = strlen(p);
        if (len > 0 && p[len - 1] == '\n') p[--len] = '\0';
        if (len > 2 && p[0] == '[' && p[len - 1] == ']')
            snprintf(sec, sizeof(sec), "%.*s", (int)(len - 2), p + 1);
        else if (strncmp(p, "api_key", 7) == 0 && n < NUM_AI) {
            char *eq = strchr(p, '=');
            if (eq) {
                char *v = eq + 1;
                while (*v == ' ' || *v == '\t' || *v == '"') v++;
                char *end = v + strlen(v) - 1;
                while (end > v && (*end == ' ' || *end == '\t' || *end == '"')) *end-- = '\0';
                snprintf(e[n].provider, sizeof(e[n].provider), "%s", sec);
                snprintf(e[n].api_key, sizeof(e[n].api_key), "%s", v);
                n++;
            }
        }
    }
    fclose(f);
fill_defaults:
    for (int i = 0; i < NUM_AI; i++) {
        int found = 0;
        for (int j = 0; j < n; j++)
            if (strcmp(e[j].provider, ai_providers[i]) == 0) found = 1;
        if (!found && n < NUM_AI) {
            snprintf(e[n].provider, sizeof(e[n].provider), "%s", ai_providers[i]);
            e[n].api_key[0] = '\0';
            n++;
        }
    }
    return n;
}

static void save_aichat(ApiKeyEntry *e, int n, const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    for (int i = 0; i < n; i++) {
        fprintf(f, "[%s]\napi_key = \"%s\"\n", e[i].provider, e[i].api_key);
        if (i < n - 1) fprintf(f, "\n");
    }
    fclose(f);
}

static void aichat_settings(void) {
    ApiKeyEntry entries[NUM_AI];
    int count = load_aichat(entries);

    char *items[NUM_AI + 1];
    char labels[NUM_AI][64];
    for (int i = 0; i < count; i++) {
        snprintf(labels[i], sizeof(labels[i]), "%.10s  %s",
                 entries[i].provider,
                 entries[i].api_key[0] ? "[已设置]" : "[未设置]");
        items[i] = labels[i];
    }

    for (;;) {
        /* rebuild labels in case keys changed */
        for (int i = 0; i < count; i++) {
            snprintf(labels[i], sizeof(labels[i]), "%.10s  %s",
                     entries[i].provider,
                     entries[i].api_key[0] ? "[已设置]" : "[未设置]");
            items[i] = labels[i];
        }
        int sel = menu_select(" AI 聊天 API 设置 ", (const char **)items, count, 0,
                               "↑↓ 选择  Enter 修改  Esc 返回");
        if (sel < 0) return;

        /* input new key */
        char prompt[128];
        snprintf(prompt, sizeof(prompt), "%s API Key:", entries[sel].provider);
        char key[MAX_KEY_LEN] = "";
        input_dialog("设置 API Key", prompt, key, sizeof(key));

        /* write temp file */
        ApiKeyEntry tmp[NUM_AI];
        memcpy(tmp, entries, sizeof(entries));
        snprintf(tmp[sel].api_key, sizeof(tmp[sel].api_key), "%s", key);
        save_aichat(tmp, count, TMP_AICHAT);

        if (confirm_dialog("确认", "保存 API 设置?")) {
            copy_file(TMP_AICHAT, AICHAT_CONFIG);
            snprintf(entries[sel].api_key, sizeof(entries[sel].api_key), "%s", key);
            msg_dialog("完成", "API 设置已保存。");
        }
        unlink(TMP_AICHAT);
    }
}

/* ---------- main ---------- */
int main(void) {
    setlocale(LC_ALL, "");
    initscr();
    cbreak();
    noecho();
    curs_set(0);
    keypad(stdscr, TRUE);
    getmaxyx(stdscr, term_h, term_w);
    init_colors();
    clearok(curscr, TRUE);

    const char *main_items[] = {
        "字体设置",
        "WiFi 设置",
        "输入法设置",
        "AI 聊天设置",
    };

    for (;;) {
        int sel = menu_select(" 系统设置 ", main_items, 4, 1,
                               "↑↓/jk 选择  Enter 进入  Esc/q 退出");
        switch (sel) {
        case 0: font_settings_menu(); break;
        case 1: wifi_settings(); break;
        case 2: im_settings(); break;
        case 3: aichat_settings(); break;
        case -1: goto quit;
        }
    }
quit:
    endwin();
    return 0;
}
