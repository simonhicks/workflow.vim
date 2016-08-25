if exists("g:did_autoload_struct")
  finish
endif
let g:did_autoload_struct = 1

" TODO
" <workflow>InsertPath
" - make sure autocomplete works for nested workflows with a slash (eg. etrog/tech)

function! s:date()
  return substitute(system('date +%Y-%m-%d'), "\n", '', '')
endfunction

function! s:has_key(workflow, key)
  return has_key(a:workflow, a:key) && a:workflow[a:key]
endfunction

function! s:has_date(workflow)
  return s:has_key(a:workflow, 'date')
endfunction

function! s:has_mandatory_title(workflow)
  return !s:has_date(a:workflow) || s:has_key(a:workflow, 'mandatory-title')
endfunction

function! s:has_nested(workflow)
  return s:has_key(a:workflow, 'nested')
endfunction

function! s:has_insert_path(workflow)
  return has_key(a:workflow, 'insertPath') && (type(a:workflow['insertPath']) ==# type({}))
endfunction

function! s:sanitize_title(title)
  let without_spaces = substitute(a:title, '[[:space:]][[:space:]]*', '-', 'g')
  let lower_case = tolower(without_spaces)
  return substitute(lower_case, '[^a-z0-9\-]', '', 'g')
endfunction

function! s:make_filename(workflow, title)
  let name = ''
  if s:has_date(a:workflow)
    let name = name . s:date()
  endif
  let title = s:sanitize_title(a:title)
  if len(name) && len(title)
    let name = name . '-'
  endif
  let name = name . title . '.' . a:workflow['ext']
  return name
endfunction

function! s:ensure_dir_exists(dir)
  if !isdirectory(a:dir)
    call system('mkdir -p '.shellescape(a:dir))
  endif
endfunction

function! s:parse_locator(workflow, locator)
  let parts = [a:locator]
  if s:has_nested(a:workflow)
    let parts = split(a:locator, '/')
  endif
  let dir = a:workflow['root']
  if s:has_nested(a:workflow)
    let dir = dir . '/' . join(parts[0:-2], '/')
  endif
  let dir = fnamemodify(dir, ':p')
  call s:ensure_dir_exists(dir)
  return { "dir": dir, "title": parts[-1] }
endfunction

function! s:path(workflow, locator)
  if s:has_mandatory_title(a:workflow) && !len(a:locator)
    throw "Invalid file locator '" . a:locator . "'"
  endif
  let locator = s:parse_locator(a:workflow, a:locator)
  if s:has_mandatory_title(a:workflow) && !len(locator['title'])
    throw "Invalid file locator '" . a:locator . "'"
  endif
  return fnamemodify(locator['dir'] .  s:make_filename(a:workflow, locator['title']), ':p')
endfunction

function! s:safeSplitType(splitType)
  if (a:splitType ==# '') && !&hidden && &modified
    echom "Force setting splitType to 'split' to avoid losing unsaved changes"
    return 'split'
  else
    return a:splitType
  endif
endfunction

function! s:newBufferCommand(splitType, path)
  if (a:splitType == 'split')
    return "new " . a:path
  elseif (a:splitType == 'vert')
    return "vert new " . a:path
  elseif (a:splitType == 'tab')
    return "tabnew " . a:path
  else
    return "edit " . a:path
  endif
endfunction

function! s:existingBufferCommand(splitType, notesBufferNum)
  if (a:splitType == 'split')
    return "split +buffer" . a:notesBufferNum
  elseif (a:splitType == 'vert')
    return "vert split +buffer" . a:notesBufferNum
  elseif (a:splitType == 'tab')
    return "tab sb " . a:notesBufferNum
  else
    return "buffer " . a:notesBufferNum
  endif
endfunction

" return true if a new buffer was created
function! s:openFile(splitType, path)
  let splitType = s:safeSplitType(a:splitType)
  let existingBufferNum = bufnr(a:path)
  let isNewBuffer = (existingBufferNum ==# -1)
  if isNewBuffer
    let command = s:newBufferCommand(splitType, a:path)
  else
    let command = s:existingBufferCommand(splitType, existingBufferNum)
  endif
  execute command
  return isNewBuffer
endfunction

function! struct#openDir(workflowName, splitType)
  let workflow = g:struct_workflows[a:workflowName]
  let root = workflow['root']
  call s:openFile(a:splitType, root)
endfunction

function! s:addMappings(workflow, mapType)
  if has_key(a:workflow, a:mapType)
    let mappings = a:workflow[a:mapType]
    for mapping in keys(mappings)
      execute a:mapType . ' <buffer> ' . mapping . ' ' . mappings[mapping]
    endfor
  end
endfunction

function! s:executeHooks(workflow, path, isNewFile)
  if has_key(a:workflow, 'onload')
    execute substitute(a:workflow['onload'], '<[Ff][Ii][Ll][Ee]>', a:path, 'g')
  end
  call s:addMappings(a:workflow, 'imap')
  call s:addMappings(a:workflow, 'cmap')
  call s:addMappings(a:workflow, 'nmap')
  call s:addMappings(a:workflow, 'inoremap')
  call s:addMappings(a:workflow, 'cnoremap')
  call s:addMappings(a:workflow, 'nnoremap')
  if a:isNewFile && has_key(a:workflow, 'oncreate')
    execute substitute(a:workflow['oncreate'], '<[Ff][Ii][Ll][Ee]>', a:path, 'g')
  end
endfunction

function! s:setAutocmds(workflow)
  if has_key(a:workflow, 'autocmd')
    let cmds = a:workflow['autocmd']
    for key in keys(cmds)
      execute 'au! '.key.' <buffer> '.cmds[key]
    endfor
  end
endfunction

function! s:makeSubstitutions()
  let curr = 0
  let subspattern = '{{{\(\(}\?}\?[^}]\)*\)}}}'
  while curr <= line("$")
    let currline = getline(curr)
    while match(currline, subspattern) != -1
      let list = matchlist(currline, subspattern)
      call setline(curr, substitute(currline, '\V'.list[0], '\='.list[1], ''))
      let currline = getline(curr)
    endwhile
    let curr = curr + 1
  endwhile
endfunction

function! s:loadTemplate(workflow)
  if has_key(a:workflow, 'template')
    execute "norm! V:read ".a:workflow['template']."kdd"
  end
endfunction

function! s:applyTemplate(workflow, locator)
  let datestr = system("date +'".g:workflow_template_date_format."'")
  let b:date = strpart(datestr, 0, len(datestr) -1)
  let b:title = s:parse_locator(a:workflow, a:locator).title
  call s:loadTemplate(a:workflow)
  call s:makeSubstitutions()
endfunction

function! s:openAndPostProcess(workflow, splitType, path, locator)
  let path = fnamemodify(a:path, ':p')
  let isNewFile = (! filereadable(path))
  let isNewBuffer = s:openFile(a:splitType, path)
  if (isNewFile && isNewBuffer)
    call s:applyTemplate(a:workflow, a:locator)
  end
  call s:executeHooks(a:workflow, path, isNewFile)
  call s:setAutocmds(a:workflow)
endfunction

function! struct#openFile(workflowName, splitType, ...)
  let locator = len(a:000) ? a:1 : ''
  let workflow = g:struct_workflows[a:workflowName]
  try
    let path = s:path(workflow, locator)
    call s:openAndPostProcess(workflow, a:splitType, path, locator)
  catch /Invalid file locator '.*/
    call s:echoError("Workflow '".a:workflowName."' requires a title")
  endtry
endfunction

" Unused args are so that this function follows the same arg pattern as the
" other user exposed functions
function! struct#loadHooks(workflowName, ...)
  let workflow = g:struct_workflows[a:workflowName]
  call s:executeHooks(workflow, expand("%"), 0)
  call s:setAutocmds(workflow)
endfunction

" Unused args are so that this function follows the same arg pattern as the
" other user exposed functions
function! struct#createHooks(workflowName, ...)
  let workflow = g:struct_workflows[a:workflowName]
  call s:executeHooks(workflow, expand("%"), 1)
  call s:setAutocmds(workflow)
endfunction

function! struct#matchingFiles(workflowName, pattern)
  let workflow = g:struct_workflows[a:workflowName]
  let dir = fnamemodify(workflow['root'], ':p')
  let paths = split(system("find '".dir."' -name "."'*".a:pattern."*' -type f"), "\n")
  return map(paths, "substitute(v:val, dir.'/', '', '')")
endfunction

function! struct#insertPathAutoComplete(argLead, cmdLine, cursorPos)
  let workflowName = strpart(a:cmdLine, 0, match(a:cmdLine, 'InsertPath'))
  return struct#matchingFiles(workflowName, a:argLead)
endfunction

function! s:matchWorkflow(string)
  for workflow in keys(g:struct_workflows)
    if match(a:string, ".*" . workflow) != -1
      return workflow
    endif
  endfor
  return -1
endfunction

" This only works for workflows which DO NOT automatically add a date (ie.
" where workflow['date'] == 0)
function! struct#openFileAutoComplete(argLead, cmdLine, cursorPos)
  let workflowName =  s:matchWorkflow(strpart(a:cmdLine, 0, match(a:cmdLine, ' ')))
  let paths = struct#matchingFiles(workflowName, a:argLead)
  return map(paths, "substitute(v:val, '\.". g:struct_workflows[workflowName]['ext'] ."$', '', '')")
endfunction

function! struct#insertPath(workflowName, path)
  let bak = @a
  let filePath = a:path
  if match(filePath, "^/.*") == -1
    let workflow = g:struct_workflows[a:workflowName]
    let absoluteDir = fnamemodify(workflow['root'], ':p')
    let filePath = fnamemodify(absoluteDir . filePath, ':p')
  endif
  if filereadable(filePath)
    let @a = filePath
    normal! "ap
    let @a = bak
  else
    call s:echoError("Invalid path: ".a:path)
  endif
endfunction

function! s:grep(workflow, query)
  let directory = substitute(a:workflow['root'], '^\~', $HOME, '')
  let resultstring = system('grep -r ' . shellescape(a:query) . ' ' . shellescape(directory))
  let dirpattern = substitute(directory.'/', '/', '\\/', 'g')
  let results = split(substitute(resultstring, dirpattern, '', 'g'), '\n')
  return results
endfunction

function! s:chooseResult(results)
  let ind = 1
  for result in a:results
    echom ind . ') ' . result
    let ind = ind + 1
  endfor
  let choice = input('Choose result: ')
  if (match(choice, '^\d\d*$') == -1 || choice >=# len(a:results))
    throw "Invalid selection"
  end
  return a:results[choice - 1]
endfunction

function! struct#grep(workflowName, splitType, query)
  try
    let workflow = g:struct_workflows[a:workflowName]
    let results = s:grep(workflow, a:query)
    if (len(results) > 0)
      let chosen = s:chooseResult(results)
      let path = workflow['root'].'/'.substitute(chosen, ':.*$', '', '')
      call s:openAndPostProcess(workflow, a:splitType, path, '')
    else
      echom "No " . a:workflowName . " results found for '" . a:query . "'"
    end
  catch /Invalid selection/
    call s:echoError("Invalid selection")
  endtry
endfunction

function! s:makeExVariants(name, command, function, withArgs)
  let types = [['', ''], ['H', 'split'], ['V', 'vert'], ['T', 'tab']]
  let nargs = a:withArgs ? '?' : '0'
  for type in types
    let command = type[0].a:name.a:command
    let argList = "'".a:name."', '".type[1]."'".(a:withArgs ? ', <f-args>' : '')
    if (s:has_date(g:struct_workflows[a:name]) == 0)
      let complOpts = '-complete=customlist,struct#openFileAutoComplete '
    else
      let complOpts = ''
    endif
    execute 'command! -nargs='.nargs.' '.complOpts.command.' call struct#'.a:function."(".argList.")"
  endfor
endfunction

function! s:setupInsertPath(name)
  let workflow = g:struct_workflows[a:name]
  if s:has_insert_path(workflow)
    let commandName = a:name.'InsertPath'
    execute 'command! -nargs=1 -complete=customlist,struct#insertPathAutoComplete '.commandName.' call struct#insertPath("'.a:name.'", <f-args>)'
    let config = workflow['insertPath']
    if has_key(config, 'globalImap')
      execute 'inoremap ' . config['globalImap'] . ' <c-o>:'.commandName.' '
    endif
  endif
endfunction

function! s:makeExCommands(name)
  call s:makeExVariants(a:name, '', 'openFile', 1)
  call s:makeExVariants(a:name, 'List', 'openDir', 0)
  call s:makeExVariants(a:name, 'Grep', 'grep', 1)
  call s:makeExVariants(a:name, 'LoadHooks', 'loadHooks', 0)
  call s:makeExVariants(a:name, 'CreateHooks', 'createHooks', 0)
  call s:setupInsertPath(a:name)
endfunction

function! s:rootIsDirectory(workflow)
  return isdirectory(fnamemodify(a:workflow['root'], ":p"))
endfunction

function! s:errorsForWorkflow(name)
  let workflow = g:struct_workflows[a:name]
  let errors = []
  if !has_key(workflow, 'ext')
    call add(errors, "does not contain the mandatory 'ext' key")
  endif
  if !has_key(workflow, 'root')
    call add(errors, "does not contain the mandatory 'root' key")
  endif
  if !s:rootIsDirectory(workflow)
    call add(errors, "root directory '".workflow['root']."' does not exist")
  endif
  return errors
endfunction

function! s:echoError(error)
  echohl Error
  echom a:error
  echohl None
endfunction

function! s:initializeWorkflow(name)
  let errors = s:errorsForWorkflow(a:name)
  if len(errors) > 0
    for error in errors
      call s:echoError("Invalid workflow '".a:name."' - ".error)
    endfor
  else
    call s:makeExCommands(a:name)
  endif
endfunction

function! struct#initialize()
  if exists("g:struct_workflows")
    for name in keys(g:struct_workflows)
      call s:initializeWorkflow(name)
    endfor
  endif
endfunction
