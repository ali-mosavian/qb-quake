#include "qglsurf.h"
#include "assets.h"

/*
 * A surface straight out of a container member. The handle is the
 * shared one asset_seek positions; qglSfLoadFh fills the surface from
 * wherever it is, which is why nothing here opens or closes a file.
 *
 * THE HEIGHT COMES FROM THE MEMBER'S SIZE, not from the caller: the
 * packer owns the atlas layout and re-deriving it here would be the
 * same fact twice. A member whose length is not a whole number of rows
 * is refused rather than rounded.
 */
QSurf qgl_surf_from_member( char *member, short wide, short whr,
                            long *out_bytes )
{
    short fh;
    long  n, rows;
    QSurf s;

    if ( out_bytes ) *out_bytes = 0;

    fh = asset_seek( member, &n );
    if ( n <= 0 || ( n % (long) wide ) != 0 ) return 0;
    rows = n / (long) wide;
    if ( rows > 32767L ) return 0;

    s = qglSfNew( wide, (short) rows, whr );
    if ( !s ) return 0;

    if ( !qglSfLoadFh( s, fh ) ) { qglSfFree( s ); return 0; }

    if ( out_bytes ) *out_bytes = n;
    return s;
}
