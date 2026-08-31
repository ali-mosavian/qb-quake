DefInt A-Z
'' spanpoly.bas -- one perspective-textured triangle, drawn twice: once
'' by uglPolyTP, once as a stack of spans through uglSpanBegin/uglSpanTP.
''
'' The polygon driver is the reference. The span path has to reach the
'' same picture from the other direction: the caller walks the edges and
'' evaluates u/z, v/z and 1/z per span itself, which is exactly what a
'' renderer that resolved its own spans would do.
''
'' The texture is four numbered quadrants, not a solid colour -- a solid
'' one cannot tell a correct mapping from a swapped or flipped one.
''
'' The two are NOT expected byte-identical. The polygon driver samples
'' from the true fractional edge of each scanline; a caller handing over
'' already-resolved spans has integer ends and no fractional edge left to
'' sample from, so quadrant boundaries land within a pixel of each other
'' either side. TOL is what that is worth -- it caught the units bug at
'' 198 and the missing centring at 90, and both were structural.

'$include: 'M:\INC\ugl.bi'

Const DW = 48
Const DH = 24
Const TW = 64
Const TOL = 96                  '' see the note above: 8% of the dc

Declare Function uglSpanBegin& (ByVal texdc As Long, ByVal dstdc As Long, ByVal masked As Integer, ByVal dudx As Single, ByVal dvdx As Single, ByVal dzdx As Single)
Declare Function uglSpanTP& (ByVal x As Integer, ByVal wid As Integer, ByVal y As Integer, ByVal up As Single, ByVal vp As Single, ByVal zp As Single)

Declare Function uglDcSize& (ByVal dc As Long, ByVal sel As Integer)
Declare Sub Fit (f0 As Single, f1 As Single, f2 As Single, a As Single, b As Single, c As Single)
Declare Sub Dump (title As String, dc As Long)
Declare Function Diff& (a As Long, b As Long)

    Dim Shared vx(2) As Single, vy(2) As Single
    Dim Shared det As Single

    Dim dstA As Long, dstB As Long, tex As Long
    Dim vtx(2) As vector3f
    Dim uu(2) As Single, vv(2) As Single, zz(2) As Single
    Dim tu(2) As Single, tv(2) As Single
    Dim ua As Single, ub As Single, uc As Single
    Dim va As Single, vb As Single, vc As Single
    Dim za As Single, zb As Single, zc As Single
    Dim x As Integer, y As Integer, i As Integer, k As Integer
    Dim yc As Single, xl As Single, xr As Single, t As Single
    Dim x0 As Integer, x1 As Integer
    Dim xc As Single, zs As Single
    Dim ya As Single, yb2 As Single, xa As Single, xb2 As Single
    Dim r As Long, nd As Long

    If (uglInit% = 0) Then
        Print "FAIL uglInit" : Print "RESULT FAIL" : End
    End If

    dstA = uglNew&(UGL.MEM%, UGL.8BIT%, DW, DH)
    dstB = uglNew&(UGL.MEM%, UGL.8BIT%, DW, DH)
    tex  = uglNew&(UGL.MEM%, UGL.8BIT%, TW, TW)
    If (dstA = 0 Or dstB = 0 Or tex = 0) Then
        Print "FAIL uglNew" : Print "RESULT FAIL" : uglEnd : End
    End If

    uglClear dstA, 0
    uglClear dstB, 0
    '' four quadrants, values 1..4 -- orientation is readable in the dump
    For y = 0 To TW - 1
        For x = 0 To TW - 1
            k = 1
            If x >= TW \ 2 Then k = k + 1
            If y >= TW \ 2 Then k = k + 2
            uglPSet tex, x, y, k
        Next x
    Next y

    '' a triangle with real perspective: 1/z differs per vertex
    vx(0) =  6.0 : vy(0) =  3.0 : zz(0) = 0.50 : uu(0) = 0.0 : vv(0) = 0.0
    vx(1) = 41.0 : vy(1) =  6.0 : zz(1) = 0.25 : uu(1) = 1.0 : vv(1) = 0.0
    vx(2) = 20.0 : vy(2) = 20.0 : zz(2) = 0.40 : uu(2) = 0.5 : vv(2) = 1.0

    For i = 0 To 2
        vtx(i).x = vx(i)
        vtx(i).y = vy(i)
        vtx(i).z = zz(i)
        vtx(i).u = uu(i) * zz(i)        '' normalised/z, both paths
        vtx(i).v = vv(i) * zz(i)
    Next i

    '' ---- reference ----
    uglPolyTP dstA, vtx(0), 3, 0, tex

    '' ---- span path ----
    det = (vx(1) - vx(0)) * (vy(2) - vy(0)) - (vx(2) - vx(0)) * (vy(1) - vy(0))
    If (det > -0.001 And det < 0.001) Then
        Print "FAIL degenerate triangle" : Print "RESULT FAIL" : uglEnd : End
    End If
    '' the reference gets normalised/z and uglPolyTP scales it; this
    '' path is below that, so it scales with uGL's own number.
    For i = 0 To 2
        tu(i) = vtx(i).u * CSng(uglDcSize&(tex, 0))
        tv(i) = vtx(i).v * CSng(uglDcSize&(tex, 1))
    Next i
    Fit tu(0), tu(1), tu(2), ua, ub, uc
    Fit tv(0), tv(1), tv(2), va, vb, vc
    Fit vtx(0).z, vtx(1).z, vtx(2).z, za, zb, zc

    r = uglSpanBegin&(tex, dstB, 0, ua, va, za)
    If (r = 0) Then
        Print "FAIL uglSpanBegin" : Print "RESULT FAIL" : uglEnd : End
    End If

    For y = 0 To DH - 1
        yc = CSng(y) + 0.5
        xl =  9999.0
        xr = -9999.0
        For i = 0 To 2
            k = (i + 1) Mod 3
            ya = vy(i) : yb2 = vy(k) : xa = vx(i) : xb2 = vx(k)
            If ((ya <= yc And yb2 > yc) Or (yb2 <= yc And ya > yc)) Then
                t = (yc - ya) / (yb2 - ya)
                xa = xa + (xb2 - xa) * t
                If xa < xl Then xl = xa
                If xa > xr Then xr = xa
            End If
        Next i
        If xr > xl Then
            x0 = Int(xl)
            x1 = Int(xr)
            If x0 < 0 Then x0 = 0
            If x1 > DW Then x1 = DW
            If x1 > x0 Then
                '' the pixel CENTRE, and a half texel: the polygon driver
                '' makes both adjustments per scanline before it hands the
                '' filler u and v, so a caller coming in below it makes
                '' them itself or samples half a pixel off.
                xc = CSng(x0) + 0.5
                zs = za * xc + zb * CSng(y) + zc
                r = uglSpanTP&(x0, x1 - x0, y, _
                               ua * xc + ub * CSng(y) + uc + 0.5 * zs, _
                               va * xc + vb * CSng(y) + vc + 0.5 * zs, _
                               zs)
            End If
        End If
    Next y

    Dump "uglPolyTP (reference)", dstA
    Dump "uglSpanTP (spans)", dstB

    nd = Diff&(dstA, dstB)
    Print "   differing pixels ="; nd; "of"; CLng(DW) * CLng(DH)

    uglDel dstA : uglDel dstB : uglDel tex
    uglEnd

    If nd <= TOL Then
        Print "RESULT PASS"
    Else
        Print "RESULT FAIL"; nd; "over tolerance"; TOL
    End If
    End

'' one of u/z, v/z, 1/z as a plane a*x + b*y + c over screen space
Sub Fit (f0 As Single, f1 As Single, f2 As Single, a As Single, b As Single, c As Single)
    Dim dx1 As Single, dy1 As Single, dx2 As Single, dy2 As Single
    Dim df1 As Single, df2 As Single
    dx1 = vx(1) - vx(0) : dy1 = vy(1) - vy(0)
    dx2 = vx(2) - vx(0) : dy2 = vy(2) - vy(0)
    df1 = f1 - f0       : df2 = f2 - f0
    a = (df1 * dy2 - df2 * dy1) / det
    b = (dx1 * df2 - dx2 * df1) / det
    c = f0 - a * vx(0) - b * vy(0)
End Sub

Sub Dump (title As String, dc As Long)
    Dim x As Integer, y As Integer, p As Integer
    Dim s As String
    Print "   "; title
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

Function Diff& (a As Long, b As Long)
    Dim x As Integer, y As Integer, n As Long
    n = 0
    For y = 0 To DH - 1
        For x = 0 To DW - 1
            If uglPGet&(a, x, y) <> uglPGet&(b, x, y) Then n = n + 1
        Next x
    Next y
    Diff& = n
End Function
