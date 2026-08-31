DefInt A-Z
'' spantst.bas -- does uglSpanTP draw one span where it is told, and
'' nowhere else?
''
'' The polygon driver is not involved at all. A solid texture means any
'' texel sampled is the same byte, so what is under test is purely the
'' addressing: the span's extent, and its ROW. Getting the row wrong is
'' invisible inside a renderer -- it just looks like a corrupt frame --
'' and is the whole reason this test exists separately.

'$include: 'M:\INC\ugl.bi'

Const DW = 64
Const DH = 64
Const TEXC = 77                 '' the texture's one colour
Const BG   = 5                  '' destination fill, != 0 on purpose
Const SX = 8                    '' span start
Const SW = 16                   '' span width
Const SY = 10                   '' span row

Declare Function uglSpanBegin& (ByVal texdc As Long, ByVal dstdc As Long, ByVal masked As Integer, ByVal dudx As Single, ByVal dvdx As Single, ByVal dzdx As Single)
Declare Function uglSpanTP& (ByVal x As Integer, ByVal wid As Integer, ByVal y As Integer, ByVal up As Single, ByVal vp As Single, ByVal zp As Single)

Declare Sub Chk (what As String, got As Long, want As Long)
Declare Function PixAt% (dc As Long, x As Integer, y As Integer)

    Dim Shared fails As Integer

    Dim dst As Long, tex As Long
    Dim r As Long

    fails = 0
    If (uglInit% = 0) Then
        Print "FAIL uglInit"
        Print "RESULT FAIL"
        End
    End If

    dst = uglNew&(UGL.MEM%, UGL.8BIT%, DW, DH)
    tex = uglNew&(UGL.MEM%, UGL.8BIT%, 64, 64)
    If (dst = 0 Or tex = 0) Then
        Print "FAIL uglNew"
        Print "RESULT FAIL"
        uglEnd
        End
    End If

    uglClear dst, BG
    uglClear tex, TEXC

    '' Constant gradients and 1/z = 1: every texel of the span samples the
    '' same place, so the only thing that can vary is WHERE it lands.
    r = uglSpanBegin&(tex, dst, 0, 0.0, 0.0, 0.0)
    If (r = 0) Then
        Print "FAIL uglSpanBegin returned 0 -- no filler for this format"
        Print "RESULT FAIL"
        uglEnd
        End
    End If

    Print "   spanbegin ->"; r
    r = uglSpanTP&(SX, SW, SY, 1.0, 1.0, 1.0)

    '' the span itself
    Chk "first px", PixAt%(dst, SX, SY), TEXC
    Chk "last px", PixAt%(dst, SX + SW - 1, SY), TEXC

    '' and nowhere else, horizontally
    Chk "before span", PixAt%(dst, SX - 1, SY), BG
    Chk "after span", PixAt%(dst, SX + SW, SY), BG

    '' and nowhere else, vertically -- the row check is the point
    Chk "row above", PixAt%(dst, SX, SY - 1), BG
    Chk "row below", PixAt%(dst, SX, SY + 1), BG
    Chk "row 0", PixAt%(dst, SX, 0), BG

    uglDel dst
    uglDel tex
    uglEnd

    If fails = 0 Then
        Print "RESULT PASS"
    Else
        Print "RESULT FAIL"; fails
    End If
    End

Function PixAt% (dc As Long, x As Integer, y As Integer)
    PixAt% = CInt(uglPGet&(dc, x, y) And 255&)
End Function

Sub Chk (what As String, got As Long, want As Long)
    If got = want Then
        Print "   ok   "; what; "="; got
    Else
        Print "   FAIL "; what; "="; got; "want"; want
        fails = fails + 1
    End If
End Sub
