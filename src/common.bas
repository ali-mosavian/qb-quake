option explicit
''
'' qini.bas -- stuff.ini parsing and the string tokeniser.
''
'' Split out of main.bas: 257 lines that touch exactly one piece of
'' shared state (env), so the module boundary costs nothing.
''
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
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'q_env.bi'

''
'' This module's own procedures.
''
declare function com_arg ( _
    strm() as string, _
    strm_cnt as integer, _
    line_num as integer _
) as string
declare function com_yesno ( _
    strm() as string, _
    strm_cnt as integer, _
    line_num as integer _
) as integer
declare sub com_check_args ( _
    strm() as string, _
    strm_cnt as integer, _
    byval want as integer, _
    byval line_num as integer _
)

''
'' This module's own procedures.
''
declare sub com_parse_config ( _
    filename as string, _
    env as Env _
)



sub com_tokenize ( _
    strm() as string, _
    strm_cnt as integer, _
    token_list as string, _
    stream as string _
)
             
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
    token_cnt = len( token_list )
    if ( token_cnt = 0  ) then exit sub
    if ( token_cnt > 50 ) then exit sub
    
    for  i = 1 to token_cnt
        token( i-1 ) = mid$( token_list, i, 1 )
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



sub com_parse_config ( _
    filename as string, _
    env as Env _
)

    const xres_flag = 1
    const yres_flag = 2
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
    const all_flag = xres_flag or yres_flag or zn_flag or zf_flag or cmscr_flag or _
                      page_flag or usepg_flag or clear_flag or cminp_flag or cmmde_flag or _
                      fov_flag or sound_flag
    
    dim flags as integer   
    dim raw_line as string
    dim line_num as integer
    dim strm(50) as string
    dim strm_cnt as integer
    dim file as integer
    
    flags = 0
    file = freefile
    
    open filename for input as #file
    
    env.c_fmt = UGL.8BIT    
            
    do 
        line input #file, raw_line
        line_num = line_num + 1
        com_tokenize strm(), strm_cnt, "  ", raw_line
        
        
        if ( strm_cnt > 0 ) then
            select case strm(0)
                case "//"
                
                case "display.xres"                
                    env.x_res = val( com_arg( strm(), strm_cnt, line_num ) )
                    flags = flags or xres_flag
                    
                case "display.yres"
                    env.y_res = val( com_arg( strm(), strm_cnt, line_num ) )
                    flags = flags or yres_flag
                    
                    
                case "display.clear"
                    env.clear_screen = com_yesno( strm(), strm_cnt, line_num )
                    flags = flags or clear_flag
                                        
                case "display.pages"
                    env.pages = val( com_arg( strm(), strm_cnt, line_num ) )
                    flags = flags or page_flag
                    
                case "display.usepaging"
                    env.use_paging = com_yesno( strm(), strm_cnt, line_num )
                    flags = flags or usepg_flag
                                    
                case "world.frustum.zn"                
                    env.z_near = val( com_arg( strm(), strm_cnt, line_num ) )
                    flags = flags or zn_flag
                                    
                case "world.frustum.zf"                
                    env.z_far = val( com_arg( strm(), strm_cnt, line_num ) )
                    flags = flags or zf_flag
                                    
                case "world.camera.script"
                    env.cam_script = com_arg( strm(), strm_cnt, line_num )
                    flags = flags or cmscr_flag
                    
                case "world.camera.interp"
                    env.cam_interp = val( com_arg( strm(), strm_cnt, line_num ) )
                    flags = flags or cminp_flag
                    
                case "world.camera.mode"
                    if ( com_arg( strm(), strm_cnt, line_num ) = "freelook" ) then
                        env.cam_mode = 0
                    elseif ( com_arg( strm(), strm_cnt, line_num ) = "script_play" ) then
                        env.cam_mode = 1
                    elseif ( com_arg( strm(), strm_cnt, line_num ) = "script_edit" ) then
                        env.cam_mode = 2
                    else
                        sys_error "Unknown syntax at line #" + str$(line_num)                                                
                    end if                    
                    
                    flags = flags or cmmde_flag
                    
                case "world.camera.fov"
                    env.cam_fov = val( com_arg( strm(), strm_cnt, line_num ) )
                    flags = flags or fov_flag
                    
                case "sound.enabled"
                    env.sound = com_yesno( strm(), strm_cnt, line_num )
                    flags = flags or sound_flag
                case else
                    sys_error "Unknown command, " + raw_line
                    
            end select                                    
        end if
        
    ''
    '' Read the whole file. This used to stop the moment every required
    '' key had been seen, so anything after the last one -- a typo, an
    '' override, a malformed line -- was silently skipped rather than
    '' reported. And the terminator tested eof(1), a hardcoded handle,
    '' while the file was opened on one from freefile.
    ''
    loop until ( eof( file ) )
    close #file
    
    if ( flags <> all_flag ) then
        sys_error "Incorrect ini file..."
    end if    

end sub



''::::::::::
'' name: com_yesno
'' desc: A boolean setting. Accepts yes/no and true/false, because the
''       file already used both -- display.clear took yes/no and
''       sound.enabled took true/false.
''
''       Three keys each carried their own two-branch test, and each had
''       the same hole: a value that was neither word left the setting at
''       its default AND its flag unset, so the failure surfaced later as
''       'Incorrect ini file' with no line number. This reports the line.
''::::::::::
function com_yesno ( _
    strm() as string, _
    strm_cnt as integer, _
    line_num as integer _
) as integer
    dim v as string

    v = com_arg( strm(), strm_cnt, line_num )

    if ( v = "yes" or v = "true" ) then
        com_yesno = true
    elseif ( v = "no" or v = "false" ) then
        com_yesno = false
    else
        sys_error "Expected yes/no at line #" + str$(line_num)
    end if

end function




''::::::::::
'' name: com_arg
'' desc: The value of a key = value line, validated on the way out.
''       Twelve cases each called com_check_args and then read strm(2)
''       themselves; coupling the two means a case cannot read an
''       argument without checking it. Hoisting the check above the
''       SELECT instead would have applied it to comment lines and to
''       unknown keys, which report a different error on purpose.
''::::::::::
function com_arg ( _
    strm() as string, _
    strm_cnt as integer, _
    line_num as integer _
) as string
    com_check_args strm(), strm_cnt, 3, line_num
    com_arg = strm(2)
end function




''::::::::::
'' name: com_check_args
'' desc: Every key in stuff.ini has the same shape: name = value, with an
''       optional // comment after it. This check was written out once per
''       case in com_parse_config -- thirteen copies, and the bulk of the routine.
''
'' Cold: one call per line of a small text file at startup.
''::::::::::
sub com_check_args ( _
    strm() as string, _
    strm_cnt as integer, _
    byval want as integer, _
    byval line_num as integer _
)

    ''
    '' A trailing // comment makes the count larger than want, with the
    '' marker at index 3. Testing strm(3) without first checking that the
    '' line HAS an index 3 read whatever the previous line left there --
    '' com_tokenize only writes the tokens it finds and never clears the
    '' rest of the array. A short malformed line following a commented one
    '' therefore skipped this check entirely.
    ''
    if ( strm_cnt <> want ) then
        if ( strm_cnt < 4 ) then
            sys_error "Unknown syntax at line #" + str$(line_num)
        elseif ( strm(3) <> "//" ) then
            sys_error "Unknown syntax at line #" + str$(line_num)
        end if
    end if

    if ( strm(1) <> "=" ) then
        sys_error "Unknown syntax at line #" + str$(line_num)
    end if

end sub
