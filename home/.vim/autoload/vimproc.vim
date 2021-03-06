"=============================================================================
" FILE: vimproc.vim
" AUTHOR:  Shougo Matsushita <Shougo.Matsu@gmail.com> (Modified)
"          Yukihiro Nakadaira <yukihiro.nakadaira at gmail.com> (Original)
" Last Modified: 17 Mar 2010
" Usage: Just source this file.
" License: MIT license  {{{
"     Permission is hereby granted, free of charge, to any person obtaining
"     a copy of this software and associated documentation files (the
"     "Software"), to deal in the Software without restriction, including
"     without limitation the rights to use, copy, modify, merge, publish,
"     distribute, sublicense, and/or sell copies of the Software, and to
"     permit persons to whom the Software is furnished to do so, subject to
"     the following conditions:
"
"     The above copyright notice and this permission notice shall be included
"     in all copies or substantial portions of the Software.
"
"     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
"     OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
"     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
"     IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
"     CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
"     TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
"     SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
" }}}
" Version: 3.01, for Vim 7.0
"=============================================================================
scriptencoding utf-8

let s:is_win = has('win32') || has('win64')
let s:last_status = 0

if exists('g:vimproc_dll_path')
  let s:dll_path = g:vimproc_dll_path
else
  let s:dll_path = expand("<sfile>:p:h") . (s:is_win || exists('$WINDIR')? '/proc.dll' : '/proc.so')
endif

"-----------------------------------------------------------
" API

function! vimproc#system(command, ...)"{{{
  " Open pipe.
  let l:subproc = vimproc#popen3(a:command)

  if !empty(a:000)
    " Write input.
    call l:subproc.stdin.write(a:1)
  endif
  call l:subproc.stdin.close()
  let l:output = ''
  while !l:subproc.stdout.eof
    let l:output .= l:subproc.stdout.read(-1, 40)
  endwhile
  let s:last_errmsg = ''
  while !l:subproc.stderr.eof
    let s:last_errmsg .= l:subproc.stderr.read(-1, 40)
  endwhile

  let [l:cond, s:last_status] = l:subproc.waitpid()
  if l:cond != 'exit'
    try
      " Kill process.
      " 15 == SIGTERM
      call l:subproc.kill(15)
    catch
      " Ignore error.
    endtry
  endif

  " Newline convert.
  if has('mac')
    let l:output = substitute(l:output, '\r', '\n', 'g')
  elseif has('win32') || has('win64')
    let l:output = substitute(l:output, '\r\n', '\n', 'g')
  endif

  return l:output
endfunction"}}}
function! vimproc#get_last_status()"{{{
  return s:last_status
endfunction"}}}
function! vimproc#get_last_errmsg()"{{{
  return s:last_errmsg
endfunction"}}}

function! vimproc#open(path, flags, ...)
  let l:mode = get(a:000, 0, 0)
  let l:fd = s:vp_file_open(a:path, a:flags, l:mode)
  return s:fdopen(l:fd, 'vp_file_close', 'vp_file_read', 'vp_file_write')
endfunction

function! vimproc#popen2(args)
  let l:pid_list = []
  let l:stdin_list = []
  let l:stdout_list = []
  for l:command in s:split_pipe(a:args)
    let [l:pid, l:fd_stdin, l:fd_stdout] = s:vp_pipe_open(2, s:convert_args(a:args))
    call add(l:pid_list, l:pid)
    call add(l:stdin_list, s:fdopen(l:fd_stdin, 'vp_pipe_close', 'vp_pipe_read', 'vp_pipe_write'))
    call add(l:stdout_list, s:fdopen(l:fd_stdout, 'vp_pipe_close', 'vp_pipe_read', 'vp_pipe_write'))
  endfor

  " Set pipe redirection.
  let i = 0
  let max = len(l:pid_list) - 1
  while i < max
    let l:stdin_list[i].redirect_fd = []
    let l:stdout_list[i].redirect_fd = [ l:stdin_list[i+1] ]

    let i += 1
  endwhile
  
  let l:stdin_list[i].redirect_fd = []
  let l:stdout_list[i].redirect_fd = []
  let l:proc = {}
  let l:proc.pid_list = l:pid_list
  let l:proc.pid = l:pid_list[-1]
  let l:proc.stdin = s:fdopen_pipes(l:stdin_list, 'vp_pipes_front_close', 'read_pipes', 'write_pipes')
  let l:proc.stdout = s:fdopen_pipes(l:stdout_list, 'vp_pipes_back_close', 'read_pipes', 'write_pipes')
  let l:proc.kill = s:funcref('vp_pipes_kill')
  let l:proc.waitpid = s:funcref('vp_waitpid')
  let l:proc.is_valid = 1

  return proc
endfunction

function! vimproc#popen3(args)
  let l:pid_list = []
  let l:stdin_list = []
  let l:stdout_list = []
  let l:stderr_list = []
  for l:command in s:split_pipe(a:args)
    let [l:pid, l:fd_stdin, l:fd_stdout, l:fd_stderr] = s:vp_pipe_open(3, s:convert_args(l:command))
    call add(l:pid_list, l:pid)
    call add(l:stdin_list, s:fdopen(l:fd_stdin, 'vp_pipe_close', 'vp_pipe_read', 'vp_pipe_write'))
    call add(l:stdout_list, s:fdopen(l:fd_stdout, 'vp_pipe_close', 'vp_pipe_read', 'vp_pipe_write'))
    call add(l:stderr_list, s:fdopen(l:fd_stderr, 'vp_pipe_close', 'vp_pipe_read', 'vp_pipe_write'))
  endfor

  " Set pipe redirection.
  let i = 0
  let max = len(l:pid_list) - 1
  while i < max
    let l:stdin_list[i].redirect_fd = []
    let l:stdout_list[i].redirect_fd = [ l:stdin_list[i+1] ]
    let l:stderr_list[i].redirect_fd = []

    let i += 1
  endwhile
  let l:stdin_list[i].redirect_fd = []
  let l:stdout_list[i].redirect_fd = []
  let l:stderr_list[i].redirect_fd = []

  let l:proc = {}
  let l:proc.pid_list = l:pid_list
  let l:proc.pid = l:pid_list[-1]
  let l:proc.stdin = s:fdopen_pipes(l:stdin_list, 'vp_pipes_front_close', 'read_pipes', 'write_pipes')
  let l:proc.stdout = s:fdopen_pipes(l:stdout_list, 'vp_pipes_back_close', 'read_pipes', 'write_pipes')
  let l:proc.stderr = s:fdopen_pipes(l:stderr_list, 'vp_pipes_back_close', 'read_pipes', 'write_pipes')
  let l:proc.kill = s:funcref('vp_pipes_kill')
  let l:proc.waitpid = s:funcref('vp_waitpid')
  let l:proc.is_valid = 1

  return proc
endfunction

function! vimproc#socket_open(host, port)
  let l:fd = s:vp_socket_open(a:host, a:port)
  return s:fdopen(l:fd, 'vp_socket_close', 'vp_socket_read', 'vp_socket_write')
endfunction

function! vimproc#ptyopen(args)
  if s:is_win
    let [l:pid, l:fd_stdin, l:fd_stdout] = s:vp_pipe_open(2, s:convert_args(a:args))
    let l:ttyname = ''

    let l:proc = s:fdopen_pty(l:fd_stdin, l:fd_stdout, 'vp_pty_close', 'vp_pty_read', 'vp_pty_write')
  else
    let [l:pid, l:fd, l:ttyname] = s:vp_pty_open(&winwidth, &winheight, s:convert_args(a:args))

    let l:proc = s:fdopen(l:fd, 'vp_pty_close', 'vp_pty_read', 'vp_pty_write')
  endif

  let l:proc.pid = l:pid
  let l:proc.ttyname = l:ttyname
  let l:proc.get_winsize = s:funcref('vp_pty_get_winsize')
  let l:proc.set_winsize = s:funcref('vp_pty_set_winsize')
  let l:proc.kill = s:funcref('vp_kill')
  let l:proc.waitpid = s:funcref('vp_waitpid')
  let l:proc.is_valid = 1

  return l:proc
endfunction

function! vimproc#kill(pid, sig)"{{{
  call s:libcall('vp_kill', [a:pid, a:sig])
endfunction"}}}

function! s:close() dict
  call self.f_close()
  let self.is_valid = 0
  let self.eof = 1
  let self.fd = -1
endfunction

function! s:read(...) dict
  let l:number = get(a:000, 0, -1)
  let l:timeout = get(a:000, 1, s:read_timeout)
  let [l:hd, l:eof] = self.f_read(l:number, l:timeout)
  let self.eof = l:eof
  return s:hd2str(l:hd)
endfunction

function! s:write(str, ...) dict
  let l:timeout = get(a:000, 0, s:write_timeout)
  let l:hd = s:str2hd(a:str)
  return self.f_write(l:hd, l:timeout)
endfunction

function! s:fdopen(fd, f_close, f_read, f_write)
  return {
        \'fd' : a:fd, 'eof' : 0, 'is_valid' : 1,  
        \'f_close' : s:funcref(a:f_close), 'f_read' : s:funcref(a:f_read), 'f_write' : s:funcref(a:f_write), 
        \'close' : s:funcref('close'), 'read' : s:funcref('read'), 'write' : s:funcref('write')
        \}
endfunction

function! s:fdopen_pty(fd_stdin, fd_stdout, f_close, f_read, f_write)
  return {
        \'fd_stdin' : a:fd_stdin, 'fd_stdout' : a:fd_stdout, 'eof' : 0, 'is_valid' : 1, 
        \'f_close' : s:funcref(a:f_close), 'f_read' : s:funcref(a:f_read), 'f_write' : s:funcref(a:f_write), 
        \'close' : s:funcref('close'), 'read' : s:funcref('read'), 'write' : s:funcref('write')
        \}
endfunction

function! s:fdopen_pipes(fd, f_close, f_read, f_write)
  return {
        \'fd' : a:fd, 'eof' : 0, 'is_valid' : 1, 
        \'f_close' : s:funcref(a:f_close),
        \'close' : s:funcref('close'), 'read' : s:funcref(a:f_read), 'write' : s:funcref(a:f_write)
        \}
endfunction

"-----------------------------------------------------------
" UTILS

function! s:str2hd(str)
  return join(map(range(len(a:str)), 'printf("%02X", char2nr(a:str[v:val]))'), '')
endfunction

function! s:hd2str(hd)
  " Since Vim can not handle \x00 byte, remove it.
  " do not use nr2char()
  " nr2char(255) => "\xc3\xbf" (utf8)
  return join(map(split(a:hd, '..\zs'), 'v:val == "00" ? "" : eval(''"\x'' . v:val . ''"'')'), '')
endfunction

function! s:str2list(str)
  return map(range(len(a:str)), 'char2nr(a:str[v:val])')
endfunction

function! s:list2str(lis)
  return s:hd2str(s:list2hd(a:lis))
endfunction

function! s:hd2list(hd)
  return map(split(a:hd, '..\zs'), 'str2nr(v:val, 16)')
endfunction

function! s:list2hd(lis)
  return join(map(a:lis, 'printf("%02X", v:val)'), '')
endfunction

function! s:convert_args(args)"{{{
  let l:args = (type(a:args) == type(""))? s:split_args(a:args) : a:args
  if empty(a:args)
    return []
  endif

  let l:args = insert(l:args[1:], s:getfilename(l:args[0]))

  if &termencoding != '' && &encoding != &termencoding
    " Convert encoding.
    call map(l:args, 'iconv(v:val, &encoding, &termencoding)')
  endif

  return l:args
endfunction"}}}

function! s:getfilename(command)"{{{
  let l:PATH_SEPARATOR = s:is_win ? '/\\' : '/'
  let l:pattern = printf('[/~]\?\f\+[%s]\f*$', l:PATH_SEPARATOR)
  if a:command =~ l:pattern
    return a:command
  endif

  " Command search.
  if s:is_win
    let l:path = substitute($PATH, '\\\?;', ',', 'g')
    if fnamemodify(a:command, ':e') != ''
      let l:files = globpath(l:path, a:command)
    else
      for l:ext in split($PATHEXT . ';.LNK', ';')
        let l:files = globpath(l:path, a:command . l:ext)
        if !empty(l:files)
          break
        endif
      endfor
    endif

    if !empty(l:files) && fnamemodify(l:files[0], ':e') ==? 'lnk'
      let l:files = resolve(l:files[0])

      if &termencoding != '' && &encoding != &termencoding
        " Convert encoding.
        let l:files = iconv(l:files, &termencoding, &encoding)
      endif
    endif
  else
    let l:path = substitute($PATH, '/\?:', ',', 'g')
    let l:files = globpath(l:path, a:command)
  endif

  if empty(l:files)
    throw printf('File: "%s" is not found.', a:command)
  endif

  return split(l:files, '\n')[0]
endfunction"}}}

function! s:split_args(script)"{{{
  let l:script = a:script
  let l:max = len(l:script)
  let l:args = []
  let l:arg = ''
  let l:i = 0
  while l:i < l:max
    if l:script[l:i] == "'"
      " Single quote.
      let l:end = matchend(l:script, "^'\\zs[^']*'", l:i)
      if l:end == -1
        throw 'Quote error'
      endif

      let l:arg .= l:script[l:i+1 : l:end-2]
      if l:arg == ''
        call add(l:args, '')
      endif

      let l:i = l:end
    elseif l:script[l:i] == '"'
      " Double quote.
      let l:end = matchend(l:script, '^"\zs\%([^"]\|\"\)*"', l:i)
      if l:end == -1
        throw 'Quote error'
      endif

      let l:arg .= substitute(l:script[l:i+1 : l:end-2], '\\"', '"', 'g')
      if l:arg == ''
        call add(l:args, '')
      endif

      let l:i = l:end
    elseif l:script[l:i] == '`'
      " Back quote.
      if l:script[l:i :] =~ '^`='
        let l:quote = matchstr(l:script, '^`=\zs[^`]*\ze`', l:i)
        let l:end = matchend(l:script, '^`=[^`]*`', l:i)
        let l:arg .= string(eval(l:quote))
      else
        let l:quote = matchstr(l:script, '^`\zs[^`]*\ze`', l:i)
        let l:end = matchend(l:script, '^`[^`]*`', l:i)
        let l:arg .= substitute(system(l:quote), '\n', ' ', 'g')
      endif
      if l:arg == ''
        call add(l:args, '')
      endif

      let l:i = l:end
    elseif l:script[i] == '\'
      " Escape.
      let l:i += 1

      if l:i > l:max
        throw 'Escape error'
      endif

      let l:arg .= l:script[i]
      let l:i += 1
    elseif l:script[i] == '#'
      " Comment.
      break
    elseif l:script[l:i] != ' '
      let l:arg .= l:script[l:i]
      let l:i += 1
    else
      " Space.
      if l:arg != ''
        call add(l:args, l:arg)
      endif

      let l:arg = ''

      let l:i += 1
    endif
  endwhile

  if l:arg != ''
    call add(l:args, l:arg)
  endif

  " Substitute modifier.
  let l:ret = []
  for l:arg in l:args
    if l:arg =~ '\%(:[p8~.htre]\)\+$'
      let l:modify = matchstr(l:arg, '\%(:[p8~.htre]\)\+$')
      let l:arg = fnamemodify(l:arg[: -len(l:modify)-1], l:modify)
    endif
    
    call add(l:ret, l:arg)
  endfor

  return l:ret
endfunction"}}}
function! s:split_pipe(script)"{{{
  if type(a:script) == type([])
    return [a:script]
  endif
  
  let l:script = ''

  let l:i = 0
  let l:max = len(a:script)
  let l:commands = []
  while l:i < l:max
    if a:script[l:i] == '|'
      " Pipe.
      call add(l:commands, l:script)

      " Search next command.
      let l:script = ''
      let l:i += 1
    elseif a:script[l:i] == "'"
      " Single quote.
      let [l:string, l:i] = s:skip_quote(a:script, l:i)
      let l:script .= l:string
    elseif a:script[l:i] == '"'
      " Double quote.
      let [l:string, l:i] = s:skip_double_quote(a:script, l:i)
      let l:script .= l:string
    elseif a:script[l:i] == '`'
      " Back quote.
      let [l:string, l:i] = s:skip_back_quote(a:script, l:i)
      let l:script .= l:string
    elseif a:script[l:i] == '\' && l:i + 1 < l:max
      " Escape.
      let l:script .= '\' . a:script[l:i+1]
      let l:i += 2
    else
      let l:script .= a:script[l:i]
      let l:i += 1
    endif
  endwhile
  
  call add(l:commands, l:script)

  return l:commands
endfunction"}}}
function! s:skip_quote(script, i)"{{{
  let l:end = matchend(a:script, "^'[^']*'", a:i)
  if l:end == -1
    throw 'Quote error'
  endif
  return [matchstr(a:script, "^'[^']*'", a:i), l:end]
endfunction"}}}
function! s:skip_double_quote(script, i)"{{{
  let l:end = matchend(a:script, '^"\%([^"]\|\"\)*"', a:i)
  if l:end == -1
    throw 'Quote error'
  endif
  return [matchstr(a:script, '^"\%([^"]\|\"\)*"', a:i), l:end]
endfunction"}}}
function! s:skip_back_quote(script, i)"{{{
  let l:end = matchend(a:script, '^`[^`]*`', a:i)
  if l:end == -1
    throw 'Quote error'
  endif
  return [matchstr(a:script, '^`[^`]*`', a:i), l:end]
endfunction"}}}

"-----------------------------------------------------------
" LOW LEVEL API

augroup vimproc
  autocmd!
  autocmd VimLeave * call s:finalize()
augroup END

" Initialize.
let s:lasterr = []
let s:read_timeout = 100
let s:write_timeout = 100

if has('iconv')
  " Dll path should be encoded with default encoding.  Vim does not convert
  " it from &enc to default encoding.
  let s:dll_path = iconv(s:dll_path, &encoding, "default")
endif

function! s:libcall(func, args)
  " End Of Value
  let l:EOV = "\xFF"
  let l:args = empty(a:args) ? '' : (join(reverse(copy(a:args)), l:EOV) . l:EOV)
  let l:stack_buf = libcall(s:dll_path, a:func, l:args)
  " Why this does not work?
  " let result = split(stack_buf, EOV, 1)
  let l:result = split(l:stack_buf, '[\xFF]', 1)
  if !empty(l:result) && l:result[-1] != ''
    let s:lasterr = l:result
    let l:msg = string(l:result)
    if has('iconv') && s:is_win
      " Kernel error message is encoded with system codepage.
      " XXX: other normal error message may be encoded with &enc.
      let l:msg = iconv(l:msg, 'default', &enc)
    endif
    throw printf('proc: %s: %s', a:func, l:msg)
  endif
  return l:result[:-2]
endfunction

function! s:SID_PREFIX()
  return matchstr(expand('<sfile>'), '<SNR>\d\+_\zeSID_PREFIX$')
endfunction

" Get funcref.
function! s:funcref(funcname)
  return function(s:SID_PREFIX().a:funcname)
endfunction

function! s:finalize()
  call s:vp_dlclose(s:dll_handle)
endfunction

function! s:vp_dlopen(path)
  let [handle] = s:libcall("vp_dlopen", [a:path])
  return handle
endfunction

function! s:vp_dlclose(handle)
  call s:libcall("vp_dlclose", [a:handle])
endfunction

function! s:vp_file_open(path, flags, mode)
  let [l:fd] = s:libcall('vp_file_open', [a:path, a:flags, a:mode])
  return l:fd
endfunction

function! s:vp_file_close() dict
  call s:libcall('vp_file_close', [self.fd])
  let self.fd = 0
endfunction

function! s:vp_file_read(number, timeout) dict
  let [l:hd, l:eof] = s:libcall('vp_file_read', [self.fd, a:number, a:timeout])
  return [l:hd, l:eof]
endfunction

function! s:vp_file_write(hd, timeout) dict
  let [l:nleft] = s:libcall('vp_file_write', [self.fd, a:hd, a:timeout])
  return l:nleft
endfunction

function! s:vp_pipe_open(npipe, argv)
  if s:is_win
    let l:cmdline = ''
    for arg in a:argv
      let l:cmdline .= '"' . substitute(arg, '"', '\\"', 'g') . '" '
    endfor
    let [l:pid; l:fdlist] = s:libcall('vp_pipe_open', [a:npipe, l:cmdline])
  else
    let [l:pid; l:fdlist] = s:libcall('vp_pipe_open',
          \ [a:npipe, len(a:argv)] + a:argv)
  endif

  return [pid] + fdlist
endfunction

function! s:vp_pipe_close() dict
  call s:libcall('vp_pipe_close', [self.fd])
endfunction

function! s:vp_pipes_front_close() dict
  call self.fd[0].close()
endfunction

function! s:vp_pipes_back_close() dict
  call self.fd[-1].close()
endfunction

function! s:vp_pipe_read(number, timeout) dict
  let [l:hd, l:eof] = s:libcall('vp_pipe_read', [self.fd, a:number, a:timeout])
  return [l:hd, l:eof]
endfunction

function! s:vp_pipe_write(hd, timeout) dict
  let [l:nleft] = s:libcall('vp_pipe_write', [self.fd, a:hd, a:timeout])
  return l:nleft
endfunction

function! s:read_pipes(...) dict
  let l:number = get(a:000, 0, -1)
  let l:timeout = get(a:000, 1, s:read_timeout)
  
  let l:output = ''
  let l:eof = 0
  for l:fd in self.fd
    if !l:fd.eof
      let l:read = l:fd.read(l:number, l:timeout)
      while l:read != ''
        if empty(l:fd.redirect_fd)
          " Append output.
          let l:output .= l:read
        else
          " Write pipe.
          for l:redirect_fd in l:fd.redirect_fd
            call l:redirect_fd.write(l:read)
          endfor
        endif

        let l:read = l:fd.read(l:number, l:timeout)
      endwhile
    else
      " Close pipe.
      for l:redirect_fd in l:fd.redirect_fd
        if l:redirect_fd.fd >= 0
          call l:redirect_fd.close()
        endif
      endfor
    endif
  endfor
  
  let self.eof = self.fd[-1].eof

  return l:output
endfunction

function! s:write_pipes(str, ...) dict
  let l:timeout = get(a:000, 0, s:write_timeout)
  
  " Write data.
  let l:nleft = self.fd[0].write(a:str, l:timeout)

  for l:fd in self.fd[: -2]
    if !l:fd.eof
      let l:read = l:fd.read([-1, l:timeout])
      while l:read != ''
        if empty(l:fd.redirect_fd)
          " Append output.
          let l:output .= l:read
        else
          " Write pipe.
          for l:redirect_fd in l:fd.redirect_fd
            call l:redirect_fd.write(l:read)
          endfor
        endif

        let l:read = l:fd.read(-1, l:timeout)
      endwhile
    else
      " Close pipe.
      for l:redirect_fd in l:fd.redirect_fd
        if l:redirect_fd.fd >= 0
          call l:redirect_fd.close()
        endif
      endfor
    endif
  endfor

  return l:nleft
endfunction

if s:is_win
  " For Windows.
  function! s:vp_pty_open(width, height, argv)
    let l:cmdline = ''
    for arg in a:argv
      let l:cmdline .= '"' . substitute(arg, '"', '\\"', 'g') . '" '
    endfor
    let [l:pid, l:fd_stdin, l:fd_stdout, l:ttyname] = s:libcall("vp_pty_open",
          \ [a:width, a:height, l:cmdline])
    return [l:pid, l:fd_stdin, l:fd_stdout, l:ttyname]
  endfunction

  function! s:vp_pty_close() dict
    call s:libcall('vp_pipe_close', [self.fd_stdin])
    call s:libcall('vp_pipe_close', [self.fd_stdout])
  endfunction

  function! s:vp_pty_read(number, timeout) dict
    let [l:hd, l:eof] = s:libcall('vp_pipe_read', [self.fd_stdout, a:number, a:timeout])
    return [l:hd, l:eof]
  endfunction

  function! s:vp_pty_write(hd, timeout) dict
    let [l:nleft] = s:libcall('vp_pipe_write', [self.fd_stdin, a:hd, a:timeout])
    return l:nleft
  endfunction

  function! s:vp_pty_get_winsize() dict
    let [width, height] = s:libcall('vp_pty_get_winsize', [self.fd_stdout])
    return [width, height]
  endfunction

  function! s:vp_pty_set_winsize(width, height) dict
    call s:libcall('vp_pty_set_winsize', [self.fd_stdout, a:width, a:height])
  endfunction

else
  function! s:vp_pty_open(width, height, argv)
    let [l:pid, l:fd, l:ttyname] = s:libcall("vp_pty_open",
          \ [a:width, a:height, len(a:argv)] + a:argv)
    return [l:pid, l:fd, l:ttyname]
  endfunction

  function! s:vp_pty_close() dict
    call s:libcall('vp_pty_close', [self.fd])
  endfunction

  function! s:vp_pty_read(number, timeout) dict
    let [l:hd, l:eof] = s:libcall('vp_pty_read', [self.fd, a:number, a:timeout])
    return [l:hd, l:eof]
  endfunction

  function! s:vp_pty_write(hd, timeout) dict
    let [l:nleft] = s:libcall('vp_pty_write', [self.fd, a:hd, a:timeout])
    return l:nleft
  endfunction

  function! s:vp_pty_get_winsize() dict
    let [width, height] = s:libcall('vp_pty_get_winsize', [self.fd])
    return [width, height]
  endfunction

  function! s:vp_pty_set_winsize(width, height) dict
    call s:libcall('vp_pty_set_winsize', [self.fd, a:width, a:height])
  endfunction

endif

function! s:vp_kill(sig) dict
  call s:libcall('vp_kill', [self.pid, a:sig])
  let self.is_valid = 0
endfunction

function! s:vp_pipes_kill(sig) dict
  for l:pid in self.pid_list
    call s:libcall('vp_kill', [l:pid, a:sig])
  endfor
  let self.is_valid = 0
endfunction

function! s:vp_waitpid() dict
  let [l:cond, l:status] = s:libcall('vp_waitpid', [self.pid])
  let self.is_valid = 0
  return [l:cond, l:status]
endfunction

function! s:vp_socket_open(host, port)
  let [socket] = s:libcall('vp_socket_open', [a:host, a:port])
  return socket
endfunction

function! s:vp_socket_close() dict
  call s:libcall('vp_socket_close', [self.fd])
endfunction

function! s:vp_socket_read(number, timeout) dict
  let [l:hd, l:eof] = s:libcall('vp_socket_read', [self.fd, a:number, a:timeout])
  return [l:hd, l:eof]
endfunction

function! s:vp_socket_write(hd, timeout) dict
  let [l:nleft] = s:libcall('vp_socket_write', [self.fd, a:hd, a:timeout])
  return l:nleft
endfunction

" Initialize.
if !exists('s:dlhandle')
  let s:dll_handle = s:vp_dlopen(s:dll_path)
endif

