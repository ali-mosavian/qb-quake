#include "qglsurf.h"

QSurf qgl_surf_from_file( const char far *path, short wide, short whr,
                          long *out_bytes )
{
    short fh;
    long  n;
    long  rows;
    QSurf s;

    if ( out_bytes ) *out_bytes = 0;
    if ( !( fh = qglFileOpen( path ) ) ) return 0;

    n = qglFileSize( fh );
    qglFileClose( fh );

    if ( n <= 0 || ( n % (long) wide ) != 0 ) return 0;
    rows = n / (long) wide;
    if ( rows > 32767L ) return 0;

    s = qglSfNew( wide, (short) rows, whr );
    if ( !s ) return 0;

    /* qglSfLoad documents its path as a bare far ptr, not ASCIIZ, so
       the generated header can only type it as the dword it is. */
    if ( !qglSfLoad( s, (long) path ) ) { qglSfFree( s ); return 0; }

    if ( out_bytes ) *out_bytes = n;
    return s;
}
