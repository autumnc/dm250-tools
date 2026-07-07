/*
 * SPDX-FileCopyrightText: 2021~2021 duzhaokun123 <duzhaokun2@outlook.com>
 * SPDX-FileCopyrightText: 2010~2021 CSSlayer <wengxt@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 */

#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <fcitx-gclient/fcitxgclient.h>
#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/fs.h>
#include <fcitx-utils/keysymgen.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/utf8.h>
#include <getopt.h>
#include <gio/gio.h>
#include "imapi.h"
#include "keycode.h"
#include "keymap.h"
#include "utils.h"

using namespace std;
using namespace fcitx;

namespace {

std::string preeditItemsToString(const GPtrArray *preedit) {
    std::string preeditString;
    for (guint i = 0; i < preedit->len; i++) {
        preeditString +=
            static_cast<FcitxGPreeditItem *>(g_ptr_array_index(preedit, i))
                ->string;
    }
    return preeditString;
}

int is_double_width(uint32_t ucs) {
    static const std::tuple<uint32_t, uint32_t> double_width[] = {
        {0x1100, 0x115F}, {0x2329, 0x232A},   {0x2E80, 0x303E},
        {0x3040, 0xA4CF}, {0xAC00, 0xD7A3},   {0xF900, 0xFAFF},
        {0xFE10, 0xFE19}, {0xFE30, 0xFE6F},   {0xFF00, 0xFF60},
        {0xFFE0, 0xFFE6}, {0x20000, 0x2FFFD}, {0x30000, 0x3FFFD}};
    auto iter =
        std::upper_bound(std::begin(double_width), std::end(double_width), ucs,
                         [](uint32_t ucs, const auto &item) {
                             return ucs < std::get<1>(item) + 1;
                         });
    if (iter == std::end(double_width)) {
        return false;
    }
    return (ucs >= std::get<0>(*iter));
}

unsigned int text_width(std::string_view str) {
    int width = 0;
    for (auto c : utf8::MakeUTF8CharRange(str)) {
        if (is_double_width(c))
            width += 2;
        else
            width += 1;
    }
    return width;
}

void printUsage(std::string_view arg0) {
    std::cout << "Usage: " << arg0 << " [options]" << std::endl
              << "Options:" << std::endl
              << "  --help        show this message" << std::endl
              << "Envrionment variables:" << std::endl
              << "  FCITX5_FBTERM_FOREGROUND=<color> set text color"
              << std::endl
              << "  FCITX5_FBTERM_BACKGROUND=<color> set window color"
              << std::endl
              << "Color:" << std::endl
              << "  Black, DarkRed, DarkGreen, DarkYellow, DarkBlue, "
                 "DarkMagenta, DarkCyan, Gray,"
              << std::endl
              << "  DarkGray, Red, Green, Yellow, Blue, Magenta, Cyan, White"
              << std::endl;
}

struct CandSeg {
    std::string text;
    ColorType color;

    bool operator==(const CandSeg& other) const {
        return text == other.text && color == other.color;
    }
};

} // namespace

class FcitxFbterm {

    enum {
        WINID_IM = 0,
        WINID_ERROR = 1,
    };

public:
    FcitxFbterm(int argc, char *argv[]);

    int exec();

private:
    void clearWin(int winid) {
        constexpr Rectangle rect0{0, 0, 0, 0};
        if (winid == WINID_IM && !winVisible_) return; // already hidden
        set_im_window(winid, rect0);
        if (winid == WINID_IM) {
            lastRect_ = rect0;
            winVisible_ = false;
        }
    }

    void moveRectInScreen(Rectangle &rect);

    void im_active();

    void im_deactive();

    void im_show();

    void im_hide();

    void process_raw_key(char *buf, unsigned int len);

    void cursor_pos_changed(unsigned x, unsigned y);

    void update_fbterm_info(::Info *info);

    void show_cannot_connect_error();

    gboolean socketCallback();

    void fcitx_fbterm_connect_cb();

    void fcitx_fbterm_commit_string_cb(const char *str);

    void fcitx_fbterm_current_im_cb(const char *name, const char *, const char *);

    void putText(const char *str);

    void writeStatusFile();

    void fcitx_fbterm_update_client_side_ui_cb(
        GPtrArray *preedit, int cursorPos, GPtrArray *auxUp, GPtrArray *auxDown,
        GPtrArray *candidates, int highlight, int layoutHint, gboolean hasPrev,
        gboolean hasNext);

    UniqueCPtr<FcitxGClient, &g_object_unref> client_;
    UniqueCPtr<GIOChannel, &g_io_channel_unref> iochannel_;
    UniqueCPtr<GMainLoop, &g_main_loop_unref> mainloop_;

    unsigned fontWidth_;
    unsigned fontHeight_;
    unsigned screenWidth_;
    unsigned screenHeight_;
    unsigned cursorx_, cursory_;
    int maxCells_ = 60;
    Rectangle lastRect_{0, 0, 0, 0};
    bool winVisible_ = false;
    int64_t lastShowTime_ = 0;

    static constexpr char useRawMode = 1;
    static constexpr int PAD = 3;
    bool active_ = false;
    bool fullwidth_ = false;
    bool raw_shift_ = false;
    bool focusInCalled_ = false;  // Track focus_in state
    fcitx::KeyState state_;
    std::string statusText_; // status from auxDown (e.g. "雾", "A")
    std::vector<CandSeg> upSegs_;   // preedit segments
    std::vector<CandSeg> downSegs_; // candidate segments
    std::vector<CandSeg> lastUpSegs_;   // cached for comparison
    std::vector<CandSeg> lastDownSegs_; // cached for comparison
    int cursorPos_ = -1;
    int lastCursorPos_ = -1;  // cached cursor position
    int lastCursorX_ = 0;     // cached cursor X coordinate
    ColorType foreground_ = Black;
    ColorType background_ = White;
    ColorType highlightColor_ = DarkBlue;
    bool quit_ = false;
};

FcitxFbterm::FcitxFbterm(int argc, char *argv[]) {

    const struct option longOptions[] = {{"help", no_argument, nullptr, 'h'}};
    int r;
    while ((r = getopt_long_only(argc, argv, "", longOptions, nullptr)) != -1) {
        switch (r) {
        case 'h':
        default:
            printUsage(argv[0]);
            quit_ = true;
            return;
        }
    }

    std::string_view background;
    if (auto *env = getenv("FCITX5_FBTERM_BACKGROUND")) {
        background = env;
    }
    std::string_view foreground;
    if (auto *env = getenv("FCITX5_FBTERM_FOREGROUND")) {
        foreground = env;
    }
    foreground_ = stringToColorType(foreground, Black);
    background_ = stringToColorType(background, White);

    auto imSocket = get_im_socket();
    if (imSocket == -1) {
        FCITX_ERROR()
            << "Can't not connect to fbterm, make sure start using `fbterm -i "
            << argv[0] << "` or in config file";
        quit_ = true;
        return;
    }

    iochannel_.reset(g_io_channel_unix_new(imSocket));
    g_io_add_watch(
        iochannel_.get(),
        static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR),
        +[](GIOChannel *, GIOCondition, gpointer user_data) {
            return static_cast<FcitxFbterm *>(user_data)->socketCallback();
        },
        this);

    client_.reset(fcitx_g_client_new());
    fcitx_g_client_set_program(client_.get(), "fbterm");
    fcitx_g_client_set_display(client_.get(), "fbterm");

    g_signal_connect(
        client_.get(), "connected",
        G_CALLBACK(+[](FcitxGClient *, void *user_data) {
            static_cast<FcitxFbterm *>(user_data)->fcitx_fbterm_connect_cb();
        }),
        this);
    g_signal_connect(
        client_.get(), "commit-string",
        G_CALLBACK(+[](FcitxGClient *, char *str, void *user_data) {
            static_cast<FcitxFbterm *>(user_data)
                ->fcitx_fbterm_commit_string_cb(str);
        }),
        this);
    g_signal_connect(
        client_.get(), "current-im",
        G_CALLBACK(+[](FcitxGClient *, char *name, char *, char *,
                       void *user_data) {
            static_cast<FcitxFbterm *>(user_data)->fcitx_fbterm_current_im_cb(name, nullptr, nullptr);
        }),
        this);
    g_signal_connect(
        client_.get(), "update-client-side-ui",
        G_CALLBACK(+[](FcitxGClient *, GPtrArray *preedit, int _cursorPos,
                       GPtrArray *auxUp, GPtrArray *auxDown,
                       GPtrArray *candidates, int highlight, int layoutHint,
                       gboolean hasPrev, gboolean hasNext, void *user_data) {
            static_cast<FcitxFbterm *>(user_data)
                ->fcitx_fbterm_update_client_side_ui_cb(
                    preedit, _cursorPos, auxUp, auxDown, candidates, highlight,
                    layoutHint, hasPrev, hasNext);
        }),
        this);

    ImCallbacks cbs = {
        [this]() { im_active(); },
        [this]() { im_deactive(); },
        [this](unsigned) { im_show(); },
        [this]() { im_hide(); },
        [this](char *keys, unsigned len) {
            process_raw_key(keys, len);
        },
        [this](unsigned x, unsigned y) {
            cursor_pos_changed(x, y);
        },
        [this](::Info *info) { update_fbterm_info(info); },
        [](char crlf, char appkey, char curo) {
            update_term_mode(crlf, appkey, curo);
        }
    };

    register_im_callbacks(cbs);
    connect_fbterm(useRawMode);

    mainloop_.reset(g_main_loop_new(nullptr, false));
}

int FcitxFbterm::exec() {
    if (quit_) {
        return 1;
    }
    // Create empty status file on start
    FILE *f = fopen("/tmp/fcitx5_status", "w");
    if (f) fclose(f);
    g_main_loop_run(mainloop_.get());
    // Delete status file on exit
    unlink("/tmp/fcitx5_status");
    return 0;
}

void FcitxFbterm::moveRectInScreen(Rectangle &rect) {
    // Prefer placing window below and right of cursor
    int x = cursorx_ + fontWidth_;
    int y = cursory_ + PAD;

    // Flip to above if overflows bottom
    if (y + rect.h > screenHeight_)
        y = cursory_ - rect.h - PAD;
    // Flip to left if overflows right
    if (x + rect.w > screenWidth_)
        x = cursorx_ - rect.w - fontWidth_;

    // Clamp to screen (never go off-screen)
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + rect.w > screenWidth_)
        x = screenWidth_ - rect.w;
    if (y + rect.h > screenHeight_)
        y = screenHeight_ - rect.h;

    rect.x = x;
    rect.y = y;
}

void FcitxFbterm::im_active() {
    if (useRawMode) {
        init_keycode_state();
    }
    active_ = true;
    statusText_ = "\xe9\x9b\xbe"; // 雾 default until IM reports actual status
    writeStatusFile();
    if (fcitx_g_client_is_valid(client_.get())) {
        fcitx_g_client_focus_in(client_.get());
    }
}

void FcitxFbterm::im_deactive() {
    clearWin(WINID_IM);
    clearWin(WINID_ERROR);
    active_ = false;
    statusText_.clear();
    writeStatusFile();
    if (fcitx_g_client_is_valid(client_.get())) {
        fcitx_g_client_focus_out(client_.get());
    }
}

void FcitxFbterm::im_show() {
    // Rate limit: skip content redraws within 50ms (but not cursor updates)
    int64_t now = g_get_monotonic_time();
    bool skipContentRedraw = (now - lastShowTime_ < 50000);

    clearWin(WINID_ERROR);

    // Check if any segment has visible text
    bool hasText = false;
    for (auto &seg : upSegs_)
        if (!seg.text.empty()) hasText = true;
    for (auto &seg : downSegs_)
        if (!seg.text.empty()) hasText = true;
    if (!hasText) {
        clearWin(WINID_IM);
        lastUpSegs_.clear();
        lastDownSegs_.clear();
        lastCursorPos_ = -1;
        return;
    }

    // Two-line layout: preedit on top, candidates below
    int upCells = 1; // left padding
    for (auto &seg : upSegs_)
        upCells += text_width(seg.text.c_str());
    upCells += 1; // right padding

    int downCells = 1;
    for (auto &seg : downSegs_)
        downCells += text_width(seg.text.c_str());
    downCells += 1;

    auto upPixelW = upCells * fontWidth_;
    auto downPixelW = downCells * fontWidth_;
    auto width = max(upPixelW, downPixelW);

    // Cap width to 80% of screen (small screen protection)
    int maxWidth = screenWidth_ * 4 / 5;
    if (width > maxWidth) width = maxWidth;

    auto height = fontHeight_ * (downSegs_.empty() ? 1 : 2) + PAD * 2;

    Rectangle rect;
    rect.w = width;
    rect.h = height;
    moveRectInScreen(rect);

    // Check if window size or position changed
    bool sizeChanged = (rect.w != lastRect_.w || rect.h != lastRect_.h);
    bool positionChanged = (rect.x != lastRect_.x || rect.y != lastRect_.y);
    bool rectChanged = (sizeChanged || positionChanged);

    // Check if content changed
    bool contentChanged = (upSegs_ != lastUpSegs_ || downSegs_ != lastDownSegs_);

    // Critical: Clear old window area BEFORE calling set_im_window
    // When window shrinks, fbterm won't trigger expose for old area
    // because intersectRectangles returns "Inside" (new rect inside old rect)
    // We must manually clear the old area to prevent residue
    // This clears old cursor as well, so no need for explicit cursor clearing later
    if (rectChanged && lastRect_.w > 0 && lastRect_.h > 0) {
        fill_rect(lastRect_, background_);
    }

    // Update window size/position
    if (rectChanged) {
        set_im_window(WINID_IM, rect);
        lastRect_ = rect;
        winVisible_ = true;
        // Force content redraw when size or position changes
        contentChanged = true;
    }

    // Redraw content if changed (or if window moved)
    if ((contentChanged || rectChanged) && !skipContentRedraw) {
        lastShowTime_ = now;

        fill_rect(rect, background_);

        // Line 1: preedit
        int x = rect.x + PAD;
        for (auto &seg : upSegs_) {
            draw_text(x, rect.y + PAD, seg.color, background_,
                      seg.text.c_str(), seg.text.length());
            x += text_width(seg.text.c_str()) * fontWidth_;
        }

        // Line 2: candidates
        x = rect.x + PAD;
        int candY = rect.y + PAD + fontHeight_;
        for (auto &seg : downSegs_) {
            draw_text(x, candY, seg.color, background_,
                      seg.text.c_str(), seg.text.length());
            x += text_width(seg.text.c_str()) * fontWidth_;
        }

        // Cache content
        lastUpSegs_ = upSegs_;
        lastDownSegs_ = downSegs_;
    }

    // Always update cursor (not affected by rate limit)
    // Cursor residue fix: understand the drawing timeline
    //
    // Timeline when window moves:
    // 1. fbterm expose clears old window (terminal background color)
    // 2. We fill_rect(lastRect_) with candidate box background
    // 3. We fill_rect(rect) with new window background
    // 4. We draw text content
    // 5. OLD cursor is still visible at old position (not cleared by steps 2-4)
    // 6. We draw NEW cursor
    // 7. OLD cursor position NOT marked dirty → residue!
    //
    // Solution: After content redraw (steps 3-4), old cursor position is covered
    // in new window. But in old window, it needs explicit clearing.
    // Since we already fill_rect(lastRect_), the old cursor is cleared.
    // No need for explicit old cursor clearing!

    if (cursorPos_ >= 0 && !upSegs_.empty() && !upSegs_[0].text.empty()) {
        auto &text = upSegs_[0].text;
        auto byteOff = std::min(static_cast<size_t>(cursorPos_), text.size());

        // Ensure bounds
        if (byteOff > text.size()) byteOff = text.size();

        auto cellOff = static_cast<int>(
            text_width(std::string_view(text).substr(0, byteOff)));
        int cursorX = rect.x + PAD + cellOff * fontWidth_;

        // Ensure cursor within window bounds
        if (cursorX >= rect.x && cursorX < rect.x + rect.w) {
            // Only clear old cursor if NO background fill happened
            // (window unchanged AND content unchanged)
            // In that case, old cursor position wasn't covered by fill_rect
            bool needClearOldCursor = (lastCursorPos_ >= 0 && !rectChanged && !contentChanged);

            if (needClearOldCursor) {
                // Window didn't move, so use current window Y coordinate
                Rectangle oldCursorRect = {lastCursorX_, rect.y + PAD, 1, fontHeight_};
                fill_rect(oldCursorRect, background_);
            }

            // Draw new cursor
            Rectangle cursorRect = {cursorX, rect.y + PAD, 1, fontHeight_};
            fill_rect(cursorRect, foreground_);

            lastCursorPos_ = cursorPos_;
            lastCursorX_ = cursorX;
        }
    } else {
        // No cursor visible, clear old cursor if needed
        if (lastCursorPos_ >= 0 && !rectChanged && !contentChanged) {
            Rectangle oldCursorRect = {lastCursorX_, rect.y + PAD, 1, fontHeight_};
            fill_rect(oldCursorRect, background_);
        }
        lastCursorPos_ = -1;
    }
}

void FcitxFbterm::im_hide() {}

void FcitxFbterm::process_raw_key(char *buf, unsigned int len) {
    auto notConnected = !fcitx_g_client_is_valid(client_.get());
    if (notConnected) {
        show_cannot_connect_error();
        clearWin(WINID_IM);
    }
    for (unsigned int i = 0; i < len; i++) {
        char down = !(buf[i] & 0x80);
        short code = buf[i] & 0x7f;

        if (!code) {
            if (i + 2 >= len)
                break;

            code = (buf[++i] & 0x7f) << 7;
            code |= buf[++i] & 0x7f;
            if (!(buf[i] & 0x80) || !(buf[i - 1] & 0x80))
                continue;
        }

        ushort linux_keysym = keycode_to_keysym(code, down);
        if (notConnected) {
            char *str = keysym_to_term_string(linux_keysym, down);
            putText(str);
            return;
        }
        FcitxKeySym keysym = linux_keysym_to_fcitx_keysym(linux_keysym, code);

        // Fullwidth toggle: Shift+Space - forward to fcitx5, also track locally
        if (down && raw_shift_ && keysym == FcitxKey_space) {
            fullwidth_ = !fullwidth_;
            writeStatusFile();
            raw_shift_ = false;
            // Let fcitx5 process it too (for actual fullwidth conversion)
        }
        // Track shift locally (KeyState doesn't support bit ops)
        if (keysym == FcitxKey_Shift_L || keysym == FcitxKey_Shift_R)
            raw_shift_ = down;

        bool isNavKey = (keysym >= FcitxKey_Home && keysym <= FcitxKey_End) ||
                        keysym == FcitxKey_Delete || keysym == FcitxKey_BackSpace ||
                        keysym == FcitxKey_Return || keysym == FcitxKey_Tab ||
                        keysym == FcitxKey_Escape ||
                        (keysym >= FcitxKey_F1 && keysym <= FcitxKey_F35);

        // Skip dbus for nav keys when IM is not showing candidates
        if (!isNavKey || winVisible_)
            fcitx_g_client_focus_in(client_.get());

        bool handled = false;
        if (!isNavKey || winVisible_)
            handled = fcitx_g_client_process_key_sync(
                client_.get(), keysym, code,
                static_cast<guint32>(state_), !down, 0) > 0;

        if (!handled) {
            char *str = keysym_to_term_string(linux_keysym, down);
            if (str)
                putText(str);
        }

        state_ = calculate_modifiers(state_, keysym, down);
    }
}

void FcitxFbterm::cursor_pos_changed(unsigned x, unsigned y) {
    cursorx_ = x;
    cursory_ = y;
    // Only redraw if IM window is visible (avoid spamming fbterm
    // with messages during rapid cursor movements like vim scrolling)
    if (winVisible_)
        im_show();
}

void FcitxFbterm::update_fbterm_info(::Info *info) {
    fontWidth_ = info->fontWidth;
    fontHeight_ = info->fontHeight;
    screenHeight_ = info->screenHeight;
    screenWidth_ = info->screenWidth;
    cursorx_ = 0;
    cursory_ = 0;
    maxCells_ = (screenWidth_ * 4 / 5) / fontWidth_ - 2;
    if (maxCells_ < 16) maxCells_ = 16;
}

void FcitxFbterm::show_cannot_connect_error() {
    constexpr std::string_view msg =
        "ERROR: Can't connect to fcitx5! Is daemon running?";
    Rectangle rect = {0, 0, 0, 0};
    rect.w = (text_width(msg.data()) + 2) * fontWidth_;
    rect.h = fontHeight_ + PAD * 2;
    moveRectInScreen(rect);
    set_im_window(WINID_ERROR, rect);
    fill_rect(rect, Red);
    draw_text(rect.x + PAD, rect.y + PAD, White, Red,
              msg.data(), msg.size());
}

gboolean FcitxFbterm::socketCallback() {
    if (!check_im_message()) {
        g_main_loop_quit(mainloop_.get());
        return false;
    }
    return true;
}

void FcitxFbterm::fcitx_fbterm_connect_cb() {
    g_assert(fcitx_g_client_is_valid(client_.get()));
    fcitx_g_client_set_capability(
        client_.get(),
        static_cast<guint64>(fcitx::CapabilityFlag::ClientSideInputPanel));
    if (active_) {
        fcitx_g_client_focus_in(client_.get());
    }
}

void FcitxFbterm::writeStatusFile() {
    const char *path = "/tmp/fcitx5_status";
    FILE *f = fopen(path, "w");
    if (!f) return;
    if (statusText_.empty()) {
        fclose(f);
        return;
    }
    const char *disp = statusText_.c_str();
    if (statusText_ == "A")
        disp = "\xe8\x8b\xb1"; // 英

    fprintf(f, "%s%s", disp, fullwidth_ ? "\xe2\x97\x8f" : "\xe2\x97\x8b");
    fclose(f);
}

void FcitxFbterm::fcitx_fbterm_commit_string_cb(const char *str) {
    putText(str);
}

void FcitxFbterm::putText(const char *str) {
    if (!str || !str[0]) return;
    if (fullwidth_) {
        std::string converted;
        const char *p = str;
        while (*p) {
            gunichar c = g_utf8_get_char(p);
            if (c >= 0x21 && c <= 0x7E)
                c += 0xFF01 - 0x21;
            else if (c == 0x20)
                c = 0x3000;
            char utf8[8];
            int len = g_unichar_to_utf8(c, utf8);
            converted.append(utf8, len);
            p = g_utf8_next_char(p);
        }
        put_im_text(converted.c_str(), converted.length());
    } else {
        put_im_text(str, strlen(str));
    }
}

void FcitxFbterm::fcitx_fbterm_current_im_cb(const char *name, const char *, const char *) {
    state_ = fcitx::KeyState::NoState;
}

void FcitxFbterm::fcitx_fbterm_update_client_side_ui_cb(
    GPtrArray *preedit, int cursorPos, GPtrArray *auxUp, GPtrArray *auxDown,
    GPtrArray *candidates, int highlight, int layoutHint, gboolean hasPrev,
    gboolean hasNext) {
    FCITX_UNUSED(hasPrev);
    FCITX_UNUSED(hasNext);
    FCITX_UNUSED(layoutHint);

    upSegs_.clear();
    downSegs_.clear();
    cursorPos_ = cursorPos;

    // Read status from auxUp (rime puts "雾"/"A" etc. here)
    std::string auxUpStr = preeditItemsToString(auxUp);
    if (active_ && !auxUpStr.empty() && auxUpStr != statusText_) {
        statusText_ = auxUpStr;
        writeStatusFile();
    }
    // Detect fullwidth from preedit text (updated on every keystroke)
    if (preedit->len > 0) {
        bool fw = false;
        for (guint i = 0; i < preedit->len; i++) {
            auto *item = static_cast<FcitxGPreeditItem *>(
                g_ptr_array_index(preedit, i));
            const char *p = item->string;
            while (p && *p) {
                gunichar c = g_utf8_get_char(p);
                if (c >= 0xFF01 && c <= 0xFF5E) { fw = true; break; }
                p = g_utf8_next_char(p);
            }
            if (fw) break;
        }
        if (fw != fullwidth_) {
            fullwidth_ = fw;
            writeStatusFile();
        }
    }

    // Collect preedit text
    std::string preeditStr = preeditItemsToString(preedit);

    // preedit cursor position adjustment
    if (cursorPos_ >= 0) {
        cursorPos_ += auxUpStr.size();
    }

    // Truncate preedit if too wide
    std::string preeditText = auxUpStr + preeditStr;
    int preeditW = text_width(preeditText.c_str());
    if (preeditW > maxCells_) {
        const char *p = preeditText.data();
        const char *end = p + preeditText.size();
        const char *cut = p;
        int w = 0;
        int limit = maxCells_ - 2;
        while (p < end && w < limit) {
            gunichar c = g_utf8_get_char(p);
            int cw = is_double_width(c) ? 2 : 1;
            if (w + cw > limit) break;
            w += cw;
            p = g_utf8_next_char(p);
            cut = p;
        }
        preeditText = std::string(preeditText.data(), cut - preeditText.data()) + "\342\200\246";
    }
    upSegs_.push_back({preeditText, foreground_});

    // Pre-calculate candidate widths
    struct CandInfo {
        std::string label;
        std::string text;
    };
    std::vector<CandInfo> candInfos;
    for (guint i = 0; i < candidates->len; i++) {
        const auto *item = static_cast<FcitxGCandidateItem *>(
            g_ptr_array_index(candidates, i));
        if (!item->candidate || !item->candidate[0]) continue;
        CandInfo ci;
        ci.label = std::to_string(i + 1) + ".";
        ci.text = item->candidate;
        candInfos.push_back(ci);
    }

    // Dynamic candidate count: drop from end until fits in maxCells
    int count = (int)candInfos.size();
    int totalW;
    auto calcWidth = [&](int n) {
        int w = 0;
        for (int i = 0; i < n; i++) {
            w += text_width(candInfos[i].label.c_str());
            w += text_width(candInfos[i].text.c_str());
            if (i + 1 < n) w += 1; // space between
        }
        return w;
    };
    while (count > 1 && calcWidth(count) > maxCells_)
        count--;

    // Build segments for display count
    for (int i = 0; i < count; i++) {
        bool isHighlight = (i == highlight);
        auto &ci = candInfos[i];

        // Truncate if single candidate still overflows
        std::string text = ci.text;
        int lastW = calcWidth(count);
        if (count == 1 && lastW > maxCells_) {
            int labelW = text_width(ci.label.c_str());
            int limit = maxCells_ - labelW - 2; // reserve for "…"
            if (limit < 2) limit = 2;
            const char *p = text.data();
            const char *end = p + text.size();
            const char *cut = p;
            int w = 0;
            while (p < end) {
                gunichar c = g_utf8_get_char(p);
                int cw = is_double_width(c) ? 2 : 1;
                if (w + cw > limit) break;
                w += cw;
                p = g_utf8_next_char(p);
                cut = p;
            }
            text = std::string(text.data(), cut - text.data()) + "\342\200\246"; // UTF-8 "…"
        }

        CandSeg numSeg;
        numSeg.text = ci.label;
        numSeg.color = isHighlight ? highlightColor_ : foreground_;
        downSegs_.push_back(numSeg);

        CandSeg textSeg;
        textSeg.text = text;
        textSeg.color = isHighlight ? highlightColor_ : foreground_;
        downSegs_.push_back(textSeg);

        if (i + 1 < count) {
            CandSeg spaceSeg;
            spaceSeg.text = " ";
            spaceSeg.color = foreground_;
            downSegs_.push_back(spaceSeg);
        }
    }

    im_show();
}

int main(int argc, char *argv[]) {
    FcitxFbterm fbterm(argc, argv);
    return fbterm.exec();
}
