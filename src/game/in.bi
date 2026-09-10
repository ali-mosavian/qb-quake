''
'' in.bi -- what the input hooks write: a word per scancode, and the mouse.
''
'' Keys is 128 words indexed by scancode, -1 while the key is down, and
'' word 0 the code of the last key pressed. The names are mgl's TKBD's,
'' so nothing that read g.env.keyboard.w had to change. MouseInf is what
'' qglMouseEvent fills: position in screen pixels, then the buttons.
''

type Keys
    lastkey as integer
    esc     as integer
    one     as integer
    two     as integer
    three   as integer
    four    as integer
    five    as integer
    six     as integer
    seven   as integer
    eight   as integer
    nine    as integer
    zero    as integer
    less    as integer
    equal   as integer
    backspc as integer
    tabk    as integer
    q       as integer
    w       as integer
    e       as integer
    r       as integer
    t       as integer
    y       as integer
    u       as integer
    i       as integer
    o       as integer
    p       as integer
    opnbrck as integer
    clsbrck as integer
    enter   as integer
    ctrl    as integer
    a       as integer
    s       as integer
    d       as integer
    f       as integer
    g       as integer
    h       as integer
    j       as integer
    k       as integer
    l       as integer
    semicol as integer
    apost   as integer
    tilde   as integer
    lshift  as integer
    bslash  as integer
    z       as integer
    x       as integer
    c       as integer
    v       as integer
    b       as integer
    n       as integer
    m       as integer
    comma   as integer
    dot     as integer
    slash   as integer
    rshift  as integer
    prt     as integer
    alt     as integer
    spcbar  as integer
    caps    as integer
    f1      as integer
    f2      as integer
    f3      as integer
    f4      as integer
    f5      as integer
    f6      as integer
    f7      as integer
    f8      as integer
    f9      as integer
    f10     as integer
    numlock as integer
    scroll  as integer
    home    as integer
    up      as integer
    pgup    as integer
    min     as integer
    left    as integer
    mid     as integer
    right   as integer
    plus    as integer
    endk    as integer
    down    as integer
    pgdw    as integer
    ins     as integer
    del     as integer
    sysreq  as integer
    reserv0 as string * 4
    f11     as integer
    f12     as integer
    reserv1 as string * 80
end type

type MouseInf
    x          as integer
    y          as integer
    any_button as integer
    left       as integer
    middle     as integer
    right      as integer
end type
