/* anland-osk.c — on-screen keyboard for X11 clients under anland 6.
 *
 * Why this exists: anland's IME bridge speaks zwp_text_input_v1/v3, i.e. it
 * only reaches Wayland-native clients.  The Xwayland in the container neither
 * runs an XIM server nor acts as a text-input client (0 matches for either in
 * the binary), so an X11/CEF client such as Steam has no input-method channel
 * at all and the Android soft keyboard never opens for it.
 *
 * anland 6 stretches every toplevel over the screen, so this cannot be a
 * window of its own: it is an override-redirect window declaring
 * WM_TRANSIENT_FOR, which mini-wm reparents into the target toplevel while
 * keeping its absolute position — a floating band over the client.  Keys are
 * injected with XTEST into whatever window holds the X input focus.
 *
 * Usage: anland-osk [-s WIDTHxHEIGHT]   (default: bottom 42% of the screen)
 * Close it with ESC or by killing the process.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/select.h>
#include <sys/time.h>

enum { KT_CHAR, KT_SHIFT, KT_BKSP, KT_ENTER, KT_TAB, KT_ESC, KT_SPACE, KT_PAGE, KT_NONE };

struct key {
    int x, y, w, h;
    int kind;
    char text;          /* KT_CHAR payload */
    const char* label;
};

#define MAXKEYS 160

static struct key keys[MAXKEYS];
static int nkeys;
static int shift_on, page;   /* page 0 = letters, 1 = symbols */
static Display* dpy;
static Window win, root, owner;
static GC gc;
static XFontStruct* font;
static int W, H;

static const char* ROW0 = "1234567890-=";
static const char* ROW1 = "qwertyuiop[]";
static const char* ROW2 = "asdfghjkl;'";
static const char* ROW3 = "zxcvbnm,./";
static const char* SYM0 = "!@#$%^&*()_+";
static const char* SYM1 = "{}|:\"<>?~`";
static const char* SYM2 = "\\=+-*/&%#@";

/* Shifted counterpart of an unshifted printable ASCII char. */
static char shifted(char c) {
    static const char* from = "`1234567890-=[]\\;',./";
    static const char* to   = "~!@#$%^&*()_+{}|:\"<>?";
    const char* p = strchr(from, c);
    if (p && c) return to[p - from];
    if (c >= 'a' && c <= 'z') return (char)(c - 'a' + 'A');
    return c;
}

static void add_key(int* x, int y, int w, int h, int kind, char c, const char* label) {
    if (nkeys >= MAXKEYS) return;
    keys[nkeys].x = *x; keys[nkeys].y = y;
    keys[nkeys].w = w;  keys[nkeys].h = h;
    keys[nkeys].kind = kind;
    keys[nkeys].text = c;
    keys[nkeys].label = label;
    nkeys++;
    *x += w + 6;
}

static void add_row(int y, int h, const char* chars, int count) {
    int usable = W - 12;
    int gap = 6 * (count - 1);
    int kw = (usable - gap) / count;
    int x = 6;
    for (int i = 0; i < count && chars[i]; i++)
        add_key(&x, y, kw, h, KT_CHAR, chars[i], NULL);
}

static void layout(void) {
    nkeys = 0;
    int rows = 5;   /* digits, qwerty, home, shift, bottom */
    int kh = (H - 12) / rows - 6;
    int y = 6;

    nkeys = 0;
    y = 6;
    const char* r1 = page == 0 ? ROW0 : SYM0;
    const char* r2 = page == 0 ? ROW1 : SYM1;
    const char* r3 = page == 0 ? ROW2 : SYM2;
    const char* r4 = page == 0 ? ROW3 : NULL;

    add_row(y, kh, r1, (int)strlen(r1));                 y += kh + 6;
    add_row(y, kh, r2, (int)strlen(r2));                 y += kh + 6;

    /* row with ENTER on the right */
    {
        int count = (int)strlen(r3) + 1;
        int gap = 6 * (count - 1);
        int kw = (W - 12 - gap) / count;
        int x = 6;
        for (int i = 0; r3[i]; i++) add_key(&x, y, kw, kh, KT_CHAR, r3[i], NULL);
        add_key(&x, y, kw, kh, KT_ENTER, 0, "ENTER");
        y += kh + 6;
    }

    /* row 4: SHIFT + letters/symbols + BACKSPACE */
    {
        int count = (r4 ? (int)strlen(r4) : (int)strlen(r1)) + 2;
        int gap = 6 * (count - 1);
        int kw = (W - 12 - gap) / count;
        int x = 6;
        add_key(&x, y, kw, kh, KT_SHIFT, 0, shift_on ? "SHIFT*" : "SHIFT");
        if (r4) {
            for (int i = 0; r4[i]; i++) add_key(&x, y, kw, kh, KT_CHAR, r4[i], NULL);
        } else {
            for (int i = 0; r1[i]; i++) add_key(&x, y, kw, kh, KT_CHAR, r1[i], NULL);
        }
        add_key(&x, y, kw, kh, KT_BKSP, 0, "BKSP");
        y += kh + 6;
    }

    /* bottom row: page | TAB | SPACE | ESC */
    {
        int gap = 6 * 3;
        int spacew = (W - 12 - gap) / 2;
        int otherw = (W - 12 - gap - spacew) / 2;
        int x = 6;
        add_key(&x, y, otherw, kh, KT_PAGE, 0, page == 0 ? "123" : "ABC");
        add_key(&x, y, otherw, kh, KT_TAB, 0, "TAB");
        add_key(&x, y, spacew, kh, KT_SPACE, ' ', NULL);
        x = W - 6 - otherw;
        add_key(&x, y, otherw, kh, KT_ESC, 0, "ESC");
    }
}

static void draw(void) {
    static int dbg = -1;
    if (dbg < 0) dbg = getenv("OSK_DEBUG_COLOR") != NULL;
    XSetForeground(dpy, gc, dbg ? 0xff00ff : 0x101014);
    XFillRectangle(dpy, win, gc, 0, 0, W, H);
    XSetForeground(dpy, gc, 0x3a3a44);
    XDrawRectangle(dpy, win, gc, 0, 0, W - 1, H - 1);
    for (int i = 0; i < nkeys; i++) {
        struct key* k = &keys[i];
        unsigned long fill = 0x2b2b33;
        if (k->kind == KT_SHIFT && shift_on) fill = 0x2f6fb2;
        else if (k->kind != KT_CHAR) fill = 0x22222a;
        XSetForeground(dpy, gc, fill);
        XFillRectangle(dpy, win, gc, k->x, k->y, k->w, k->h);
        XSetForeground(dpy, gc, 0x50505c);
        XDrawRectangle(dpy, win, gc, k->x, k->y, k->w - 1, k->h - 1);
        XSetForeground(dpy, gc, 0xf0f0f6);
        const char* s;
        char tmp[2];
        if (k->kind == KT_CHAR) {
            tmp[0] = k->text; tmp[1] = 0;
            s = tmp;
        } else {
            s = k->label;          /* KT_SPACE carries no label */
            if (!s) s = " ";
        }
        int tw = font ? XTextWidth(font, s, (int)strlen(s)) : 7 * (int)strlen(s);
        int tx = k->x + (k->w - tw) / 2;
        int ty = font ? k->y + (k->h + font->ascent - font->descent) / 2
                      : k->y + (k->h + 10) / 2;
        XDrawString(dpy, win, gc, tx, ty, s, (int)strlen(s));
    }
    XFlush(dpy);
}

static void inject(KeySym sym, int with_shift) {
    KeyCode kc = XKeysymToKeycode(dpy, sym);
    if (!kc) return;
    KeyCode sh = XKeysymToKeycode(dpy, XK_Shift_L);
    if (with_shift) XTestFakeKeyEvent(dpy, sh, True, 0);
    XTestFakeKeyEvent(dpy, kc, True, 0);
    XTestFakeKeyEvent(dpy, kc, False, 0);
    if (with_shift) XTestFakeKeyEvent(dpy, sh, False, 0);
    XFlush(dpy);
}

static void press(struct key* k) {
    char s[2];
    switch (k->kind) {
    case KT_CHAR: {
        char c = k->text;
        char out = shift_on ? shifted(c) : c;
        s[0] = out; s[1] = 0;
        KeySym sym = XStringToKeysym(s);
        if (sym == NoSymbol) return;
        inject(sym, 0);          /* the char already carries the shift */
        if (shift_on) { shift_on = 0; layout(); draw(); }
        break;
    }
    case KT_SPACE:  inject(XK_space, 0); break;
    case KT_ENTER:  inject(XK_Return, 0); break;
    case KT_TAB:    inject(XK_Tab, 0); break;
    case KT_BKSP:   inject(XK_BackSpace, 0); break;
    case KT_SHIFT:  shift_on = !shift_on; layout(); draw(); break;
    case KT_PAGE:   page = !page; layout(); draw(); break;
    case KT_ESC:    exit(0);
    default: break;
    }
}

/* root-child toplevel holding the input focus */
static Window focus_toplevel(void) {
    Window f = None;
    int rev;
    XGetInputFocus(dpy, &f, &rev);
    if (f == None || f == PointerRoot || f == root) return None;
    for (Window cur = f; cur != None && cur != root; ) {
        Window r, p, *kids = NULL;
        unsigned n = 0;
        if (!XQueryTree(dpy, cur, &r, &p, &kids, &n)) return None;
        if (kids) XFree(kids);
        if (p == root) return cur == win ? None : cur;
        cur = p;
    }
    return None;
}

static void screen_size(int* w, int* h) {
    Window r;
    int x, y;
    unsigned bw, d;
    XGetGeometry(dpy, root, &r, &x, &y, (unsigned*)w, (unsigned*)h, &bw, &d);
}

/* anland publishes a transient portrait mode while a window is being mapped,
 * so the screen can still be square at startup (2780x2780 -> 2780x1264).
 * Waiting for two equal reads one second apart keeps the band on screen
 * instead of parked at y = 2780 - 530, far below the visible area. */
static void settle_screen(void) {
    int lw = 0, lh = 0, same = 0;
    for (int i = 0; i < 40 && same < 5; i++) {
        int w = 0, h = 0;
        screen_size(&w, &h);
        if (w == lw && h == lh) same++;
        else { same = 0; lw = w; lh = h; }
        usleep(200000);
    }
}

/* The band has to sit inside the OWNER's rect, not the screen's.
 *
 * mini-wm adopts the band by re-parenting it into the owner toplevel, and the
 * renderer composites that toplevel's area only.  At zoom 100 % the owner
 * fills the screen and both agree — but the daemon can apply a zoom factor
 * (#31; auto_scale on a phone panel asks for 350 %), and the owner is then
 * phys×100/zoom (361x794 inside a 1264x2780 screen).  A screen-anchored band
 * lands entirely outside the composited rect: the process stays alive and the
 * window is still IsViewable, yet no pixel reaches the screen.  Deriving the
 * band from the owner makes every zoom factor behave the same. */
static int owner_rect(int* ox, int* oy, int* ow, int* oh) {
    if (!owner) return 0;
    Window r;
    int x = 0, y = 0;
    unsigned w = 0, h = 0, bw = 0, d = 0;
    if (!XGetGeometry(dpy, owner, &r, &x, &y, &w, &h, &bw, &d)) return 0;
    if ((int)w < 64 || (int)h < 64) return 0;
    *ox = x; *oy = y; *ow = (int)w; *oh = (int)h;
    return 1;
}

/* Place the band along the bottom edge of the owner (root coordinates: the
 * band is still a child of root when this runs, and mini-wm's adoption keeps
 * the absolute position).  No owner yet → the screen bottom, as before. */
static void place_in_owner(void) {
    int ox = 0, oy = 0, ow = 0, oh = 0;
    if (!owner_rect(&ox, &oy, &ow, &oh)) {
        int sw = 0, sh = 0;
        screen_size(&sw, &sh);
        if (sw <= 0 || sh <= 0) return;
        W = sw;
        H = sh * 42 / 100;
        XMoveResizeWindow(dpy, win, 0, sh - H, W, H);
        fprintf(stderr, "anland-osk: band %dx%d at 0,%d (no owner)\n", W, H, sh - H);
        return;
    }
    W = ow;
    H = oh * 42 / 100;
    if (H < 120) H = 120;
    if (H > oh) H = oh;
    XMoveResizeWindow(dpy, win, ox, oy + oh - H, W, H);
    fprintf(stderr, "anland-osk: band %dx%d at %d,%d (owner %dx%d)\n",
            W, H, ox, oy + oh - H, ow, oh);
}

/* Re-place the band after the output size changed: back onto the root first,
 * because a reparented child would otherwise be positioned in owner space. */
static void reparks(void) {
    int sw = 0, sh = 0;
    screen_size(&sw, &sh);
    if (sw <= 0 || sh <= 0) return;
    XUnmapWindow(dpy, win);
    XReparentWindow(dpy, win, root, 0, 0);
    if (owner) XSetTransientForHint(dpy, win, owner);
    place_in_owner();
    XMapRaised(dpy, win);
    XFlush(dpy);
    layout();
    draw();
    fprintf(stderr, "anland-osk: re-parked %dx%d\n", W, H);
}

/* Steam is a CEF app: a single toplevel holding full-size child windows.
 * Every repaint raises one of them above the band, so the band has to be
 * nudged back on top.  Two cheap round trips, only when needed. */
static void keep_on_top(void) {
    Window r, parent, *kids = NULL;
    unsigned n = 0;
    if (!win || !XQueryTree(dpy, win, &r, &parent, &kids, &n)) return;
    if (kids) XFree(kids);
    if (!parent) return;
    Window rr, pp, *sib = NULL;
    unsigned ns = 0;
    if (!XQueryTree(dpy, parent, &rr, &pp, &sib, &ns)) return;
    int top = (ns == 0) || (sib[ns - 1] == win);
    if (sib) XFree(sib);
    if (!top) { XRaiseWindow(dpy, win); XFlush(dpy); }
}

static void attach(Window target) {
    owner = target;
    XUnmapWindow(dpy, win);
    XSetTransientForHint(dpy, win, owner);
    place_in_owner();      /* band follows the owner, not the screen (zoom) */
    XMapRaised(dpy, win);
    XFlush(dpy);
    layout();
    draw();
}

static void anchor(Window target) {
    if (target == None || target == owner) return;
    attach(target);
    fprintf(stderr, "anland-osk: anchored to 0x%lx\n", owner);
}

/* mini-wm adopts the band by re-parenting it into the owner toplevel.  That
 * link is fragile: a re-map after an output change, an Android task switch or
 * the owner itself being remapped drops the band back onto the root, where
 * nothing composites it — the process stays alive and the window is still
 * IsViewable, yet no pixel reaches the screen.  Re-run the handshake when the
 * parent is no longer the owner, at most once every two seconds so a hostile
 * WM cannot spin us. */
static void verify_parent(void) {
    if (!owner) return;
    Window r, parent, *kids = NULL;
    unsigned n = 0;
    if (!XQueryTree(dpy, win, &r, &parent, &kids, &n)) return;
    if (kids) XFree(kids);
    if (parent == owner) return;
    static long last = 0;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    long now = tv.tv_sec;
    if (now - last < 2) return;
    last = now;
    fprintf(stderr, "anland-osk: parent is 0x%lx, expected 0x%lx — re-anchoring\n",
            (unsigned long)parent, (unsigned long)owner);
    attach(owner);
    layout();
    draw();
}

int main(int argc, char** argv) {
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "anland-osk: no display\n"); return 1; }
    root = DefaultRootWindow(dpy);
    int sw = DisplayWidth(dpy, DefaultScreen(dpy));
    int sh = DisplayHeight(dpy, DefaultScreen(dpy));
    settle_screen();
    screen_size(&sw, &sh);
    W = sw;
    H = sh * 42 / 100;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-s") && i + 1 < argc) {
            int a, b;
            if (sscanf(argv[++i], "%dx%d", &a, &b) == 2) { W = a; H = b; }
        }
    }

    XSetWindowAttributes swa;
    swa.override_redirect = True;
    swa.background_pixel = 0x101014;
    swa.event_mask = ExposureMask | ButtonPressMask;
    win = XCreateWindow(dpy, root, 0, sh - H,
                        W, H, 0, CopyFromParent, InputOutput, CopyFromParent,
                        CWOverrideRedirect | CWBackPixel | CWEventMask, &swa);
    XSelectInput(dpy, root, StructureNotifyMask);
    XStoreName(dpy, win, "anland-osk");
    gc = XCreateGC(dpy, win, 0, NULL);
    static const char* fonts[] = { "9x15", "6x13", "fixed", "10x20" };
    for (unsigned i = 0; i < sizeof(fonts)/sizeof(fonts[0]) && !font; i++)
        font = XLoadQueryFont(dpy, fonts[i]);
    if (font) XSetFont(dpy, gc, font->fid);
    else fprintf(stderr, "anland-osk: no font available, labels unmeasured\n");

    fprintf(stderr, "osk: window created, owner=%lx\n", (unsigned long)focus_toplevel());
    anchor(focus_toplevel());
    fprintf(stderr, "osk: anchored\n");
    if (!owner) fprintf(stderr, "anland-osk: no focused toplevel yet\n");
    layout();
    fprintf(stderr, "osk: layout ok, %d keys\n", nkeys);
    draw();
    fprintf(stderr, "osk: draw ok\n");
    XFlush(dpy);
    fprintf(stderr, "anland-osk: %dx%d, %d keys\n", W, H, nkeys);

    int redraw_tick = getenv("OSK_REDRAW") != NULL;
    int xfd = ConnectionNumber(dpy);
    for (;;) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(xfd, &fds);
        struct timeval tv = { 0, 300000 };
        if (select(xfd + 1, &fds, NULL, NULL, &tv) > 0) {
            while (XPending(dpy)) {
                XEvent e;
                XNextEvent(dpy, &e);
                if (e.type == Expose) {
                    draw();
                    XRaiseWindow(dpy, win);
                    XFlush(dpy);
                } else if (e.type == ConfigureNotify && e.xconfigure.window == root) {
                    int nw = e.xconfigure.width, nh = e.xconfigure.height;
                    if (nw != W || nh * 42 / 100 != H) reparks();
                } else if (e.type == ButtonPress) {
                    for (int i = 0; i < nkeys; i++) {
                        struct key* k = &keys[i];
                        if (e.xbutton.x >= k->x && e.xbutton.x < k->x + k->w &&
                            e.xbutton.y >= k->y && e.xbutton.y < k->y + k->h) {
                            press(k);
                            break;
                        }
                    }
                }
            }
        } else {
            Window t = focus_toplevel();
            if (t != None && t != owner) anchor(t);
            else {
                verify_parent();
                keep_on_top();
                if (redraw_tick) draw();
            }
        }
    }
    return 0;
}
