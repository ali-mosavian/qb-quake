DefInt A-Z
'' spanrsp.bas -- r_span.c end to end, with nothing else in the way.
''
'' Two overlapping quads go in through r_span_emit_poly; r_span_flush
'' resolves them into non-overlapping spans and draws each one through
'' uGL's scanline filler. What is under test is r_span.c itself: the
'' plane fits, the edge bucketing, the sweep, and the per-span draw.
''
'' The assertion no polygon-at-a-time renderer can make is the overlap.
'' Depth here is EMISSION ORDER -- a later polygon is nearer, which is
'' what the BSP walk hands d_poly -- so the second quad must win every
'' pixel the two share, and the first must keep every pixel it does not.
''
'' Solid textures, one value each: which quad painted a pixel is then a
'' single byte, and no texture-mapping question is mixed in.

'$include: 'M:\INC\ugl.bi'

Const DW = 48
Const DH = 24
Const FARV = 2                  '' the first-emitted quad's texture
Const NEARV = 7                 '' the second-emitted quad's

Declare Sub r_span_start_frame ()
Declare Sub r_span_draw_to (ByVal dc As Long)
Declare Sub r_span_emit_poly (ByVal n As Integer, x() As Single, y() As Single, u() As Single, v() As Single, z() As Single, ByVal texdc As Long, ByVal texofs As Long)
Declare Function r_span_flush% (ByVal w As Integer, ByVal h As Integer)
Declare Function r_span_overflow_count% ()

Declare Sub Quad (x0 As Single, y0 As Single, x1 As Single, y1 As Single)
Declare Sub Chk (what As String, got As Long, want As Long)
Declare Sub Dump (dc As Long)

    Dim Shared fails As Integer
    Dim Shared qx(3) As Single, qy(3) As Single
    Dim Shared qu(3) As Single, qv(3) As Single, qz(3) As Single

    Dim dst As Long, texF As Long, texN As Long
    Dim n As Integer

    fails = 0
    If (uglInit% = 0) Then
        Print "FAIL uglInit" : Print "RESULT FAIL" : End
    End If

    dst  = uglNew&(UGL.MEM%, UGL.8BIT%, DW, DH)
    texF = uglNew&(UGL.MEM%, UGL.8BIT%, 64, 64)
    texN = uglNew&(UGL.MEM%, UGL.8BIT%, 64, 64)
    If (dst = 0 Or texF = 0 Or texN = 0) Then
        Print "FAIL uglNew" : Print "RESULT FAIL" : uglEnd : End
    End If
    uglClear dst, 0
    uglClear texF, FARV
    uglClear texN, NEARV

    r_span_start_frame
    r_span_draw_to dst

    '' first emitted = farther
    Quad 4.0, 4.0, 28.0, 14.0
    r_span_emit_poly 4, qx(), qy(), qu(), qv(), qz(), texF, 0&

    '' second = nearer, overlapping the first over x 16..28, y 9..14
    Quad 16.0, 9.0, 40.0, 19.0
    r_span_emit_poly 4, qx(), qy(), qu(), qv(), qz(), texN, 0&

    n = r_span_flush%(DW, DH)
    Print "   spans ="; n; " overflow ="; r_span_overflow_count%

    Dump dst

    Chk "far only", uglPGet&(dst, 8, 6) And 255&, FARV
    Chk "near only", uglPGet&(dst, 36, 17) And 255&, NEARV
    Chk "overlap -> nearer", uglPGet&(dst, 22, 11) And 255&, NEARV
    Chk "outside", uglPGet&(dst, 45, 2) And 255&, 0
    Chk "far, left of overlap", uglPGet&(dst, 8, 11) And 255&, FARV
    Chk "near, below far", uglPGet&(dst, 22, 17) And 255&, NEARV

    uglDel dst : uglDel texF : uglDel texN
    uglEnd

    If fails = 0 Then
        Print "RESULT PASS"
    Else
        Print "RESULT FAIL"; fails
    End If
    End

'' an axis-aligned quad, wound so vertices 0,1,2 are not collinear
Sub Quad (x0 As Single, y0 As Single, x1 As Single, y1 As Single)
    Dim i As Integer
    qx(0) = x0 : qy(0) = y0
    qx(1) = x1 : qy(1) = y0
    qx(2) = x1 : qy(2) = y1
    qx(3) = x0 : qy(3) = y1
    '' 1/z constant: depth here is emission order, not geometry. u and v
    '' are normalised over z, the same units uglPolyTP takes.
    For i = 0 To 3
        qz(i) = 1.0
        qu(i) = 0.0
        qv(i) = 0.0
    Next i
    qu(1) = 1.0 : qu(2) = 1.0
    qv(2) = 1.0 : qv(3) = 1.0
End Sub

Sub Dump (dc As Long)
    Dim x As Integer, y As Integer, p As Integer
    Dim s As String
    For y = 0 To DH - 1
        s = "   "
        For x = 0 To DW - 1
            p = CInt(uglPGet&(dc, x, y) And 255&)
            If p = 0 Then
                s = s + "."
            Else
                s = s + Chr$(48 + p)
            End If
        Next x
        Print s
    Next y
End Sub

Sub Chk (what As String, got As Long, want As Long)
    If got = want Then
        Print "   ok   "; what; "="; got
    Else
        Print "   FAIL "; what; "="; got; "want"; want
        fails = fails + 1
    End If
End Sub
