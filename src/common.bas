option explicit
''
'' qini.bas -- stuff.ini parsing and the string tokeniser.
''
'' Split out of main.bas: 257 lines that touch exactly one piece of
'' shared state (env), so the module boundary costs nothing.
''
defint a-z
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'pal.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
'$include: 'arch.bi'
'$include: 'uglu.bi'
'$include: 'font.bi'
'$include: 'mouse.bi'
'$include: 'bspfile.bi'
'$include: 'quakedef.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'



defint a-z
sub strtok ( strm() as string, strm_cnt as integer, _
             tokenlist as string, stream as string )
             
    dim char as string * 1
    dim i as integer, j as integer    
    
    dim is_a_tok as integer
    dim token_cnt as integer
    dim last_char_tok as integer
    dim token(50-1) as string * 1    
    
    dim stream_len as integer            
    dim stream_pos as integer    
    dim crnt_strm_indx as integer
    
    
    ''
    '' Reset vars 
    ''    
    strm_cnt   = 0    
    token_cnt  = 0
    stream_pos = 0
    crnt_strm_indx = 0
    strm(crnt_strm_indx) = ""
    
    
    ''
    '' Check stream length
    ''
    stream_len = len( stream )
    if ( stream_len = 0 ) then exit sub
        
    ''
    '' Exract tokens
    ''
    token_cnt = len( tokenlist )
    if ( token_cnt = 0  ) then exit sub
    if ( token_cnt > 50 ) then exit sub
    
    for  i = 1 to token_cnt
        token( i-1 ) = mid$( tokenlist, i, 1 )
    next i
    
    ''
    '' Tokenize
    '' 
    for  i = 1 to stream_len
        
        ''
        '' Get a char
        ''
        char = mid$( stream, i, 1 )
    
        ''
        '' Compare current char against all tokens
        '' 
        is_a_tok = false
        
        for  j = 0 to token_cnt-1
            if ( char = token(j) ) then
                is_a_tok = true
                exit for
            end if                
        next j
        
        ''
        '' If the current char isn't a token, we should
        '' add it do the out stream 
        ''
        if ( is_a_tok = false ) then
            strm(crnt_strm_indx) = strm(crnt_strm_indx) + char
            
        else         
            ''
            '' New stream
            ''
            if ( last_char_tok = false ) then
                crnt_strm_indx = crnt_strm_indx + 1
                strm(crnt_strm_indx) = ""
            end if                            
        end if
        
        last_char_tok = is_a_tok
    next i    
    
    ''
    '' Tell the user the stream count
    ''
    if ( len( strm(crnt_strm_indx) ) = 0 ) then 
        strm_cnt = crnt_strm_indx
    else
        strm_cnt = crnt_strm_indx + 1
    end if
            
end sub



defint a-z
sub parseIni ( filename as string )

    const xres_flag = 1
    const yres_flag = 2
    const cfmt_flag = 4
    const zn_flag   = 8
    const zf_flag   = 16
    const cmscr_flag= 32
    const page_flag = 64
    const usepg_flag= 128
    const clear_flag= 256
    const cminp_flag= 512
    const cmmde_flag= 1024
    const fov_flag  = 2048
    const sound_flag= 4096
    const all_flag% = xres_flag or yres_flag or zn_flag or zf_flag or cmscr_flag or _
                      page_flag or usepg_flag or clear_flag or cminp_flag or cmmde_flag or _
                      fov_flag or sound_flag
    
    dim flags as integer   
    dim rawline as string
    dim linenum as integer
    dim strm(50) as string
    dim strm_cnt as integer
    dim file as integer
    
    flags = 0
    file = freefile
    
    open filename for input as #file
    
    env.cFmt = UGL.8BIT    
            
    do 
        line input #file, rawline        
        strtok strm(), strm_cnt, "  ", rawline
        
        
        if ( strm_cnt > 0 ) then
            select case strm(0)
                case "//"
                
                case "display.xres"                
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.xRes = val( strm(2) )
                    flags = flags or xres_flag
                    
                case "display.yres"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.yRes = val( strm(2) )
                    flags = flags or yres_flag
                    
                    
                case "display.clear"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    if ( strm(2) = "no" ) then
                        env.disclear = false
                        flags = flags or clear_flag
                    elseif ( strm(2) = "yes" ) then
                        env.disclear = true
                        flags = flags or clear_flag
                    end if
                                        
                case "display.pages"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.pages = val( strm(2) )
                    flags = flags or page_flag
                    
                case "display.usepaging"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    if ( strm(2) = "no" ) then
                        env.usepag = false
                        flags = flags or usepg_flag
                    elseif ( strm(2) = "yes" ) then
                        env.usepag = true
                        flags = flags or usepg_flag
                    end if
                                    
                case "world.frustum.zn"                
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.zNear = val( strm(2) )
                    flags = flags or zn_flag
                                    
                case "world.frustum.zf"                
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.zFar = val( strm(2) )
                    flags = flags or zf_flag
                                    
                case "world.camera.script"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.camscrpt = strm(2)
                    flags = flags or cmscr_flag
                    
                case "world.camera.interp"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.caminterp = val( strm(2) )
                    flags = flags or cminp_flag
                    
                case "world.camera.mode"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    if ( strm(2) = "freelook" ) then
                        env.cammode = 0
                    elseif ( strm(2) = "script_play" ) then
                        env.cammode = 1
                    elseif ( strm(2) = "script_edit" ) then
                        env.cammode = 2
                    else
                        ExitError "Uknown syntax at line # " + str$(linenum)                                                
                    end if                    
                    
                    flags = flags or cmmde_flag
                    
                case "world.camera.fov"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    env.camfov = val( strm(2) )
                    flags = flags or fov_flag
                    
                case "sound.enabled"
                    iniCheck strm(), strm_cnt, 3, linenum
                    
                    if ( strm(2) = "false" ) then
                        env.sound = false
                        flags = flags or sound_flag
                    elseif ( strm(2) = "true" ) then
                        env.sound = true
                        flags = flags or sound_flag
                    end if                    
                
                case else
                    ExitError "Unknown command, " + rawline
                    
            end select                                    
        end if
        
        if ( flags = all_flag% ) then
            exit do
        end if
    
    loop until ( eof( 1 ) )
    close #file
    
    if ( flags <> all_flag% ) then
        ExitError "Incorrect ini file..."
    end if    

end sub



''::::::::::
'' name: iniCheck
'' desc: Every key in stuff.ini has the same shape: name = value, with an
''       optional // comment after it. This check was written out once per
''       case in parseIni -- thirteen copies, and the bulk of the routine.
''
'' Cold: one call per line of a small text file at startup.
''::::::::::
defint a-z
sub iniCheck ( strm() as string, strm_cnt as integer, _
               byval want as integer, byval linenum as integer )

    if ( (strm_cnt <> want) and (strm(3) <> "//") ) then
        ExitError "Uknown syntax at line # " + str$(linenum)
    end if

    if ( strm(1) <> "=" ) then
        ExitError "Uknown syntax at line # " + str$(linenum)
    end if

end sub
