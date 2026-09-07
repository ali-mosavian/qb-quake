option explicit
''
'' qglchk.bas -- the qgl ABI, checked from the side that has to trust it.
''
'' -qglcheck runs this and exits. It is the only BASIC caller of qgl in
'' the tree, which is the point: qgl.bi is generated from qgl.inc so the
'' two cannot drift on paper, and this is the other half -- it calls the
'' real entry points with the real constants through the real calling
'' convention, against the linked object rather than the header.
''
'' IT DOES NOT ASK THE LAYER WHAT IT BELIEVES. An introspection call that
'' reports its own constants proves two declarations agree and passes
'' happily while qglSfNew goes on misreading the value. So this creates
'' surfaces of both kinds and works them: writes a byte through a mapped
'' row, reads it back, and requires the round trip. Revert the selector
'' scaling in qgl$Row and QGL_SURF_EMS = 2 indexes two bytes into a
'' ten-byte record, the row accessor is whatever half-entry lies there,
'' and the round trip fails.
''
'' No shared state: every routine takes what it needs and returns its
'' result, so a caller can run one check without the others.
''

defint a-z

'$include: 'qgl.bi'

declare function qglSfInit () as integer
declare function qglSfNew ( byval wid as integer, byval hgt as integer, _
                              byval whr as integer, byval slot as integer ) as long
declare function qglSfRdRow ( byval s as long, byval y as integer ) as long
declare function qglSfWrRow ( byval s as long, byval y as integer ) as long
declare function qglSfPget ( byval s as long, byval x as integer, _
                               byval y as integer ) as integer
declare sub qglSfPset ( byval s as long, byval x as integer, _
                          byval y as integer, byval c as integer )
declare sub qglSfFree ( byval s as long )
declare function qglMemAvail ( byval what as integer ) as long
declare function qglGemFrame () as integer

declare function qgl_chk_kind ( byval kind as integer, byval slot as integer, _
                                nm as string, byval fh as integer ) as integer
declare function qglCheckAll () as integer

''
'' One kind of surface, created and actually used. Returns the number of
'' failures, so nothing is shared and nothing is assumed.
''
'' 64 wide is deliberate: an EMS surface's stride must divide a 16K page,
'' and 64 does. The pixels checked are the two corners and one interior
'' point, which is enough to catch a row accessor that returns a constant
'' or the wrong row.
''
function qgl_chk_kind ( byval kind as integer, byval slot as integer, _
                        nm as string, byval fh as integer ) as integer
    dim s as long
    dim bad as integer
    dim y as integer
    dim got as integer
    dim rowseg as long
    dim frame as long

    bad = 0
    s = qglSfNew( 64, 8, kind, slot )
    if ( s = 0 ) then
        '' No store of this kind is a fact about the machine, not about
        '' the ABI -- at this point in startup BASIC owns every byte of
        '' conventional memory and DOS reports nothing free. Say so and
        '' do not count it, but only when the store really is empty: a
        '' refusal with memory available is a failure.
        if ( kind = QGL_SURF_CMEM and qglMemAvail( QGL_MEM_LARGEST ) = 0 ) then
            print #fh, "   note "; nm; " skipped: DOS has no conventional memory"
            qgl_chk_kind = 0
        else
            print #fh, "   FAIL "; nm; " qglSfNew returned 0"
            qgl_chk_kind = 1
        end if
        exit function
    end if

    '' AND IT MUST BE THE RIGHT MEMORY. A round trip alone proves the
    '' address is writable, not that it is the store that was asked for.
    '' With the kind used raw as a table offset, an EMS surface lands on
    '' the conventional accessor, which reads the EMS HANDLE as a segment
    '' and writes into the interrupt vector table -- which is RAM, so it
    '' round trips perfectly while corrupting low memory. Measured: that
    '' mutation passed this test until the check below existed.
    ''
    '' An EMS surface's rows live in the page frame. Nothing else does.
    if ( kind = QGL_SURF_EMS ) then
        rowseg = qglSfRdRow( s, 0 ) \ 65536
        if ( rowseg < 0 ) then rowseg = rowseg + 65536
        frame = qglGemFrame()
        if ( frame < 0 ) then frame = frame + 65536
        if ( rowseg < frame or rowseg >= frame + 4096 ) then
            print #fh, "   FAIL "; nm; " row not in the EMS page frame:"; _
                       " rowseg="; rowseg; " frame="; frame
            bad = bad + 1
        end if
    end if

    '' write a value that depends on the row, so a row accessor that
    '' always answers the same address cannot pass
    for y = 0 to 7
        qglSfPset s, 0,  y, 16 + y
        qglSfPset s, 63, y, 96 + y
    next y

    for y = 0 to 7
        got = qglSfPget( s, 0, y )
        if ( got <> 16 + y ) then
            bad = bad + 1
            if ( bad = 1 ) then
                print #fh, "        first bad: y="; y; " got="; got; _
                           " want="; 16 + y; " surf="; s
            end if
        end if
        got = qglSfPget( s, 63, y )
        if ( got <> 96 + y ) then bad = bad + 1
    next y

    qglSfFree s

    if ( bad = 0 ) then
        print #fh, "   ok   "; nm
    else
        print #fh, "   FAIL "; nm; " bad pixels:"; bad
    end if
    qgl_chk_kind = bad
end function

''
'' Every check, and the total. Printing is here rather than in the caller
'' so the flag's handler stays one line.
''
function qglCheckAll () as integer
    dim bad as integer
    dim fh as integer

    '' A FILE, not PRINT and a redirect. BASIC's PRINT goes to the
    '' display, so `qrender.exe -qglcheck > out.txt` produces an empty
    '' file and a run that looks like it said nothing -- which is the
    '' trap AGENTS.md already records for ExitError.
    fh = freefile
    open "qglchk.log" for output as #fh

    bad = 0
    if ( qglSfInit() = 0 ) then
        print #fh, "   note EMS unavailable; the conventional check still runs"
    end if

    '' The EMS one is the assertion that matters here: QGL_SURF_EMS = 2 is
    '' the value that drifted, and reaching the EMS accessors at all means
    '' the assembly read that 2 as a kind and scaled it. Revert the scaling
    '' in qgl$Row and this stops round-tripping.
    bad = bad + qgl_chk_kind( QGL_SURF_CMEM, 0, "cmem surface round trip", fh )
    bad = bad + qgl_chk_kind( QGL_SURF_EMS,  0, "ems  surface round trip", fh )

    if ( bad = 0 ) then
        print #fh, "RESULT PASS"
    else
        print #fh, "RESULT FAIL"
    end if
    close #fh
    qglCheckAll = bad
end function
