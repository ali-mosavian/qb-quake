/*
 * qgltypes.h -- the records qgl's entry points take by pointer.
 *
 * These are not qgl STRUCs: the asm sees `far ptr real4` and counts
 * offsets, so the layout is the contract and the names are ours. They
 * are transcribed from the BASIC types the same entry points are
 * declared against, which is what the asm was written to match.
 */
#ifndef QGLTYPES_H
#define QGLTYPES_H

/* A qgl surface. It is a far pointer carried as a dword -- the value
   BASIC declares `as long` and d_faces.c has always declared `long` --
   so it is named rather than spelled as a C pointer, which would invite
   a far-to-near cast that compiles silently and drops the segment. */
typedef long QSurf;

typedef struct { float x, y, z; } Vec3;

/* Row-major. Named fields, not float[16]: the asm addresses them by
   offset either way, and the BASIC Mat4 these entries are declared
   against names them the same, so a call site that says .m41 is
   reading the same word on both sides. */
typedef struct {
    float m11, m12, m13, m14;
    float m21, m22, m23, m24;
    float m31, m32, m33, m34;
    float m41, m42, m43, m44;
} Mat4;

typedef struct { unsigned char red, green, blue; } PalRgb;

/* qgl$KbdIsr writes a word per scancode and puts the last code in
   slot 0, so this is one table and not 87 named fields. */
#define QGL_KEYS 87
typedef struct { short k[QGL_KEYS]; } Keys;


/* Scancode per key, in the order qgl$KbdIsr fills the table: the
   handler writes a word at [code], and slot 0 doubles as the last
   code seen. Names and order are in.bi's Keys, which the same ISR
   fills on the BASIC side -- one table, two spellings of it. */
#define KEY_LASTKEY 0
#define KEY_ESC     1
#define KEY_ONE     2
#define KEY_TWO     3
#define KEY_THREE   4
#define KEY_FOUR    5
#define KEY_FIVE    6
#define KEY_SIX     7
#define KEY_SEVEN   8
#define KEY_EIGHT   9
#define KEY_NINE    10
#define KEY_ZERO    11
#define KEY_LESS    12
#define KEY_EQUAL   13
#define KEY_BACKSPC 14
#define KEY_TABK    15
#define KEY_Q       16
#define KEY_W       17
#define KEY_E       18
#define KEY_R       19
#define KEY_T       20
#define KEY_Y       21
#define KEY_U       22
#define KEY_I       23
#define KEY_O       24
#define KEY_P       25
#define KEY_OPNBRCK 26
#define KEY_CLSBRCK 27
#define KEY_ENTER   28
#define KEY_CTRL    29
#define KEY_A       30
#define KEY_S       31
#define KEY_D       32
#define KEY_F       33
#define KEY_G       34
#define KEY_H       35
#define KEY_J       36
#define KEY_K       37
#define KEY_L       38
#define KEY_SEMICOL 39
#define KEY_APOST   40
#define KEY_TILDE   41
#define KEY_LSHIFT  42
#define KEY_BSLASH  43
#define KEY_Z       44
#define KEY_X       45
#define KEY_C       46
#define KEY_V       47
#define KEY_B       48
#define KEY_N       49
#define KEY_M       50
#define KEY_COMMA   51
#define KEY_DOT     52
#define KEY_SLASH   53
#define KEY_RSHIFT  54
#define KEY_PRT     55
#define KEY_ALT     56
#define KEY_SPCBAR  57
#define KEY_CAPS    58
#define KEY_F1      59
#define KEY_F2      60
#define KEY_F3      61
#define KEY_F4      62
#define KEY_F5      63
#define KEY_F6      64
#define KEY_F7      65
#define KEY_F8      66
#define KEY_F9      67
#define KEY_F10     68
#define KEY_NUMLOCK 69
#define KEY_SCROLL  70
#define KEY_HOME    71
#define KEY_UP      72
#define KEY_PGUP    73
#define KEY_MIN     74
#define KEY_LEFT    75
#define KEY_MID     76
#define KEY_RIGHT   77
#define KEY_PLUS    78
#define KEY_ENDK    79
#define KEY_DOWN    80
#define KEY_PGDW    81
#define KEY_INS     82
#define KEY_DEL     83
#define KEY_SYSREQ  84
#define KEY_F11     85
#define KEY_F12     86

typedef struct {
    short x, y;
    short any, left, middle, right;
} MouseInf;

/* x, y, 1/z, u, v -- what qglRsPoly walks. */
typedef struct { float x, y, z, u, v; } QVert;

#endif
