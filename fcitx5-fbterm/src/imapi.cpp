/*
 * SPDX-FileCopyrightText: 2008~2010 dragchan <zgchan317@gmail.com>
 * SPDX-FileCopyrightText: 2021~2021 CSSlayer <wengxt@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 */

#include "imapi.h"
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcitx-utils/fs.h>
#include <vector>

#define OFFSET(TYPE, MEMBER) ((size_t)(&(((TYPE *)0)->MEMBER)))
#define MSG(a) ((Message *)(a))

static int imfd = -1;
static ImCallbacks cbs;
static char pending_msg_buf[10240];
static unsigned pending_msg_buf_len = 0;
static int im_active = 0;

void register_im_callbacks(ImCallbacks callbacks) { cbs = callbacks; }

int get_im_socket() {
    static char init = 0;
    if (!init) {
        init = 1;

        char *val = getenv("FBTERM_IM_SOCKET");
        if (val) {
            char *tail;
            int fd = strtol(val, &tail, 0);
            if (!*tail)
                imfd = fd;
        }
    }

    return imfd;
}

void connect_fbterm(char raw) {
    get_im_socket();
    if (imfd == -1)
        return;

    Message msg;
    msg.type = Connect;
    msg.len = sizeof(msg);
    msg.raw = (raw ? 1 : 0);

    ssize_t ret = fcitx::fs::safeWrite(imfd, (char *)&msg, sizeof(msg));
    if (ret != sizeof(msg)) {
        close(imfd);
        imfd = -1;
    }
}

void put_im_text(const char *text, unsigned len) {
    if (imfd == -1 || !im_active || !text || !len ||
        (OFFSET(Message, texts) + len > UINT16_MAX))
        return;

    // Limit max length to prevent excessive memory usage
    if (len > 4096) len = 4096;

    // Use std::vector instead of VLA to avoid stack overflow
    std::vector<char> buf(OFFSET(Message, texts) + len);

    MSG(buf.data())->type = PutText;
    MSG(buf.data())->len = buf.size();
    memcpy(MSG(buf.data())->texts, text, len);

    fcitx::fs::safeWrite(imfd, buf.data(), MSG(buf.data())->len);
}

void set_im_window(unsigned id, Rectangle rect) {
    if (imfd == -1 || !im_active || id >= NR_IM_WINS)
        return;

    Message msg;
    msg.type = SetWin;
    msg.len = sizeof(msg);
    msg.win.winid = id;
    msg.win.rect = rect;

    fcitx::fs::safeWrite(imfd, (char *)&msg, sizeof(msg));
    // Removed synchronous wait - fbterm-mod uses double buffering
    // which guarantees no flicker when commands are batched
    // wait_message(AckWin);
}

void fill_rect(Rectangle rect, unsigned char color) {
    Message msg;
    msg.type = FillRect;
    msg.len = sizeof(msg);

    msg.fillRect.rect = rect;
    msg.fillRect.color = color;

    fcitx::fs::safeWrite(imfd, (char *)&msg, sizeof(msg));
}

void draw_text(unsigned x, unsigned y, unsigned char fc, unsigned char bc,
               const char *text, unsigned len) {
    if (!text || !len)
        return;

    // Limit max length to prevent excessive memory usage
    if (len > 10240) len = 10240;

    // Use std::vector instead of VLA to avoid stack overflow
    std::vector<char> buf(OFFSET(Message, drawText.texts) + len);

    MSG(buf.data())->type = DrawText;
    MSG(buf.data())->len = buf.size();

    MSG(buf.data())->drawText.x = x;
    MSG(buf.data())->drawText.y = y;
    MSG(buf.data())->drawText.fc = fc;
    MSG(buf.data())->drawText.bc = bc;
    memcpy(MSG(buf.data())->drawText.texts, text, len);

    fcitx::fs::safeWrite(imfd, buf.data(), MSG(buf.data())->len);
}

static int process_message(Message *msg) {
    int exit = 0;

    switch (msg->type) {
    case Disconnect:
        close(imfd);
        imfd = -1;
        exit = 1;
        break;

    case FbTermInfo:
        if (cbs.fbterm_info) {
            cbs.fbterm_info(&msg->info);
        }
        break;

    case Active:
        im_active = 1;
        if (cbs.active) {
            cbs.active();
        }
        break;

    case Deactive:
        if (cbs.deactive) {
            cbs.deactive();
        }
        im_active = 0;
        break;

    case ShowUI:
        if (im_active && cbs.show_ui) {
            cbs.show_ui(msg->winid);
        }
        break;

    case HideUI: {
        if (im_active && cbs.hide_ui) {
            cbs.hide_ui();
        }

        Message msg;
        msg.type = AckHideUI;
        msg.len = sizeof(msg);
        fcitx::fs::safeWrite(imfd, (char *)&msg, sizeof(msg));
        break;
    }

    case SendKey:
        if (im_active && cbs.send_key) {
            cbs.send_key(msg->keys, msg->len - OFFSET(Message, keys));
        }
        break;

    case CursorPosition:
        if (im_active && cbs.cursor_position) {
            cbs.cursor_position(msg->cursor.x, msg->cursor.y);
        }
        break;

    case TermMode:
        if (im_active && cbs.term_mode) {
            cbs.term_mode(msg->term.crWithLf, msg->term.applicKeypad,
                          msg->term.cursorEscO);
        }
        break;

    default:
        break;
    }

    return exit;
}

static int process_messages(char *buf, int len) {
    char *cur = buf, *end = cur + len;
    int exit = 0;

    for (; cur < end && MSG(cur)->len <= (end - cur); cur += MSG(cur)->len) {
        exit |= process_message(MSG(cur));
    }

    return exit;
}

int check_im_message() {
    if (imfd == -1)
        return 0;

    char buf[sizeof(pending_msg_buf)];
    int len, exit = 0;

    if (pending_msg_buf_len) {
        len = pending_msg_buf_len;
        pending_msg_buf_len = 0;

        memcpy(buf, pending_msg_buf, len);
        exit |= process_messages(buf, len);
    }

    len = read(imfd, buf, sizeof(buf));

    if (len == -1 && (errno == EAGAIN || errno == EINTR))
        return 1;
    else if (len <= 0) {
        close(imfd);
        imfd = -1;
        return 0;
    }

    exit |= process_messages(buf, len);

    return !exit;
}
