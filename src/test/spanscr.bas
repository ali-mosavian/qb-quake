DefInt A-Z
'' spanscr.bas -- the same span path, drawn to the actual screen.
''
'' Four overlapping quads, each with perspective across it, emitted back
'' to front and resolved by r_span.c into non-overlapping spans. Drawing
'' straight into the video dc rather than a MEM buffer also exercises the
'' scanline table's bank handling, which a small off-screen dc never
'' makes interesting.

'$include: 'M:\INC\ugl.bi'

Const SW = 320
Const SH = 200
Const TS = 64

Declare Sub r_span_start_frame ()
Declare Sub r_span_draw_to (ByVal dc As Long)
Declare Sub r_span_emit_poly (ByVal n As Integer, x() As Single, y() As Single, u() As Single, v() As Single, z() As Single, ByVal texdc As Long, ByVal texofs As Long)
Declare Function r_span_flush% (ByVal w As Integer, ByVal h As Integer)
Declare Function r_span_overflow_count% ()

Declare Sub Checker (dc As Long, ca As Integer, cb As Integer)

    Dim Shared qx(3) As Single, qy(3) As Single
    Dim Shared qu(3) As Single, qv(3) As Single, qz(3) As Single

    Dim vdc As Long, tex(3) As Long
    Dim i As Integer, k As Integer, n As Integer
    Dim x0 As Single, y0 As Single, x1 As Single, y1 As Single
    Dim zl As Single, zr As Single

    If (uglInit% = 0) Then Print "FAIL uglInit" : End

    vdc = uglSetVideoDC&(UGL.8BIT%, SW, SH, 1)
    If (vdc = 0) Then Print "FAIL uglSetVideoDC" : uglEnd : End

    For i = 0 To 3
        tex(i) = uglNew&(UGL.MEM%, UGL.8BIT%, TS, TS)
    Next i
    Checker tex(0), 1, 9
    Checker tex(1), 2, 10
    Checker tex(2), 4, 12
    Checker tex(3), 14, 6

    uglClear vdc, 0

    '' control: a known-good uGL call straight to the video dc. If this
    '' shows and the spans do not, the span path is at fault; if neither
    '' shows, nothing is reaching the screen and the spans are innocent.
    uglRectF vdc, 4, 4, 80, 16, 15
    uglRectF vdc, 4, 182, 80, 194, 14

    r_span_start_frame
    r_span_draw_to vdc

    '' back to front: a later polygon is the nearer one
    For i = 0 To 3
        x0 = 24.0 + CSng(i) * 38.0
        y0 = 22.0 + CSng(i) * 26.0
        x1 = x0 + 150.0
        y1 = y0 + 96.0
        zl = 1.0                        '' left edge near
        zr = 0.42                       '' right edge far -> foreshortened
        qx(0) = x0 : qy(0) = y0 : qz(0) = zl
        qx(1) = x1 : qy(1) = y0 : qz(1) = zr
        qx(2) = x1 : qy(2) = y1 : qz(2) = zr
        qx(3) = x0 : qy(3) = y1 : qz(3) = zl
        '' normalised over z, the units uglPolyTP takes
        qu(0) = 0.0 * qz(0) : qv(0) = 0.0 * qz(0)
        qu(1) = 1.0 * qz(1) : qv(1) = 0.0 * qz(1)
        qu(2) = 1.0 * qz(2) : qv(2) = 1.0 * qz(2)
        qu(3) = 0.0 * qz(3) : qv(3) = 1.0 * qz(3)
        r_span_emit_poly 4, qx(), qy(), qu(), qv(), qz(), tex(i), 0&
    Next i

    n = r_span_flush%(SW, SH)

    '' long enough to be caught on screen, and it exits on a key
    Sleep 45

    uglRestore
    For i = 0 To 3
        uglDel tex(i)
    Next i
    uglEnd
    Print "spans"; n; " overflow"; r_span_overflow_count%
    End

Sub Checker (dc As Long, ca As Integer, cb As Integer)
    Dim x As Integer, y As Integer, c As Integer
    For y = 0 To TS - 1
        For x = 0 To TS - 1
            If (((x \ 8) + (y \ 8)) And 1) = 0 Then c = ca Else c = cb
            uglPSet dc, x, y, c
        Next x
    Next y
End Sub
