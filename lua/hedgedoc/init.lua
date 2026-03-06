local M = {}

local uv = vim.uv or vim.loop

local defaults = {
  base_url = "",
  token = nil,
  headers = {},
  timeout_ms = 10000,
  poll_interval_ms = 10000,
  notify = true,
  filetype = "markdown",
  endpoints = {
    get = "/api/notes/%s",
    put = "/api/notes/%s",
    revision = "/api/notes/%s/revision",
  },
}

local state = {
  opts = vim.deepcopy(defaults),
  buffers = {},
}

local function notify(msg, level)
  if not state.opts.notify then
    return
  end

  vim.notify(msg, level or vim.log.levels.INFO, { title = "hedgedoc.nvim" })
end

local function trim_trailing_slash(s)
  return (s:gsub("/+$", ""))
end

local function make_url(path)
  local base = trim_trailing_slash(state.opts.base_url)
  return base .. path
end

local function deep_merge(a, b)
  return vim.tbl_deep_extend("force", a, b or {})
end

local function parse_body_and_status(raw)
  if not raw then
    return "", 0
  end

  local body, code = raw:match("^(.*)\n(%d%d%d)%s*$")
  if not body then
    return raw, 0
  end

  return body, tonumber(code) or 0
end

local function run_curl(method, path, body)
  local url = make_url(path)
  local args = {
    "curl",
    "-sS",
    "-X",
    method,
    "--connect-timeout",
    tostring(math.max(1, math.floor(state.opts.timeout_ms / 1000))),
    "--max-time",
    tostring(math.max(1, math.floor(state.opts.timeout_ms / 1000))),
    "-w",
    "\n%{http_code}",
  }

  local headers = vim.deepcopy(state.opts.headers or {})
  if state.opts.token and state.opts.token ~= "" and not headers.Authorization then
    headers.Authorization = "Bearer " .. state.opts.token
  end

  if body then
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
  end

  for k, v in pairs(headers) do
    table.insert(args, "-H")
    table.insert(args, string.format("%s: %s", k, v))
  end

  table.insert(args, url)

  local result = vim.system(args, {
    text = true,
    stdin = body,
  }):wait()

  if result.code ~= 0 then
    return nil, string.format("request failed (%s): %s", url, (result.stderr or "")):gsub("\n+$", "")
  end

  local body_text, status = parse_body_and_status(result.stdout)
  if status < 200 or status >= 300 then
    return nil, string.format("HTTP %d from %s: %s", status, url, body_text)
  end

  return body_text, nil
end

local function run_curl_async(method, path, body, cb)
  local url = make_url(path)
  local args = {
    "curl",
    "-sS",
    "-X",
    method,
    "--connect-timeout",
    tostring(math.max(1, math.floor(state.opts.timeout_ms / 1000))),
    "--max-time",
    tostring(math.max(1, math.floor(state.opts.timeout_ms / 1000))),
    "-w",
    "\n%{http_code}",
  }

  local headers = vim.deepcopy(state.opts.headers or {})
  if state.opts.token and state.opts.token ~= "" and not headers.Authorization then
    headers.Authorization = "Bearer " .. state.opts.token
  end

  if body then
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
  end

  for k, v in pairs(headers) do
    table.insert(args, "-H")
    table.insert(args, string.format("%s: %s", k, v))
  end

  table.insert(args, url)

  vim.system(args, {
    text = true,
    stdin = body,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb(nil, string.format("request failed (%s): %s", url, (result.stderr or "")):gsub("\n+$", ""))
        return
      end

      local body_text, status = parse_body_and_status(result.stdout)
      if status < 200 or status >= 300 then
        cb(nil, string.format("HTTP %d from %s: %s", status, url, body_text))
        return
      end

      cb(body_text, nil)
    end)
  end)
end

local function decode_json_or_nil(data)
  if not data or data == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then
    return nil
  end

  return decoded
end

local function extract_doc(payload)
  if type(payload) ~= "table" then
    return nil, "invalid response: expected JSON object"
  end

  local content = payload.content or payload.text or payload.markdown
  local revision = payload.revision or payload.rev or payload.version

  if type(content) ~= "string" then
    return nil, "invalid response: missing string content"
  end

  revision = tonumber(revision)
  if not revision then
    return nil, "invalid response: missing numeric revision"
  end

  return {
    content = content,
    revision = revision,
  }, nil
end

local function fetch_document(doc_id)
  local path = string.format(state.opts.endpoints.get, doc_id)
  local body, err = run_curl("GET", path)
  if err then
    return nil, err
  end

  local payload = decode_json_or_nil(body)
  local doc, parse_err = extract_doc(payload)
  if parse_err then
    return nil, parse_err
  end

  return doc, nil
end

local function fetch_document_async(doc_id, cb)
  local path = string.format(state.opts.endpoints.get, doc_id)
  run_curl_async("GET", path, nil, function(body, err)
    if err then
      cb(nil, err)
      return
    end

    local payload = decode_json_or_nil(body)
    local doc, parse_err = extract_doc(payload)
    if parse_err then
      cb(nil, parse_err)
      return
    end

    cb(doc, nil)
  end)
end

local function save_document(doc_id, content, revision)
  local path = string.format(state.opts.endpoints.put, doc_id)
  local req = vim.json.encode({ content = content, revision = revision })

  local body, err = run_curl("PUT", path, req)
  if err then
    return nil, err
  end

  local payload = decode_json_or_nil(body) or {}
  local new_revision = tonumber(payload.revision or payload.rev or payload.version)
  return new_revision, nil
end

local function fetch_revision_async(doc_id, cb)
  local path = string.format(state.opts.endpoints.revision, doc_id)
  run_curl_async("GET", path, nil, function(body, err)
    if err then
      cb(nil, err)
      return
    end

    local payload = decode_json_or_nil(body)
    if type(payload) == "table" then
      local rev = tonumber(payload.revision or payload.rev or payload.version)
      if rev then
        cb(rev, nil)
        return
      end
    end

    cb(nil, "invalid response: missing numeric revision")
  end)
end

local function split_lines_keep_empty(s)
  local lines = vim.split(s, "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function disable_buffer_for_conflict(bufnr, remote_rev)
  local bstate = state.buffers[bufnr]
  if not bstate or bstate.readonly then
    return
  end

  bstate.readonly = true
  bstate.remote_revision = remote_rev

  pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })

  notify(
    string.format(
      "HedgeDoc note '%s' changed remotely (rev %d -> %d). Buffer set to read-only.",
      bstate.doc_id,
      bstate.revision,
      remote_rev
    ),
    vim.log.levels.WARN
  )
end

local function load_remote_into_buffer(bufnr)
  local bstate = state.buffers[bufnr]
  if not bstate or bstate.refreshing then
    return
  end

  bstate.refreshing = true
  fetch_document_async(bstate.doc_id, function(doc, err)
    local latest = state.buffers[bufnr]
    if not latest then
      return
    end

    latest.refreshing = false

    if err then
      notify(string.format("Reload failed for '%s': %s", latest.doc_id, err), vim.log.levels.ERROR)
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    if vim.bo[bufnr].modified then
      disable_buffer_for_conflict(bufnr, doc.revision)
      return
    end

    local lines = split_lines_keep_empty(doc.content)

    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = bufnr })
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)

    latest.revision = doc.revision
    latest.remote_revision = doc.revision
    vim.bo[bufnr].modified = false

    notify(string.format("Reloaded '%s' to remote revision %d", latest.doc_id, doc.revision), vim.log.levels.INFO)
  end)
end

local function stop_polling(bufnr)
  local bstate = state.buffers[bufnr]
  if not bstate or not bstate.timer then
    return
  end

  bstate.timer:stop()
  bstate.timer:close()
  bstate.timer = nil
end

local function poll_remote_revision(bufnr)
  local bstate = state.buffers[bufnr]
  if not bstate or bstate.saving or bstate.readonly or bstate.checking then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    stop_polling(bufnr)
    state.buffers[bufnr] = nil
    return
  end

  bstate.checking = true
  fetch_revision_async(bstate.doc_id, function(remote_rev, err)
    local latest = state.buffers[bufnr]
    if not latest then
      return
    end

    latest.checking = false

    if err then
      notify(string.format("Revision check failed for '%s': %s", latest.doc_id, err), vim.log.levels.DEBUG)
      return
    end

    if remote_rev > latest.revision then
      if vim.bo[bufnr].modified then
        disable_buffer_for_conflict(bufnr, remote_rev)
      else
        load_remote_into_buffer(bufnr)
      end
    end
  end)
end

local function start_polling(bufnr)
  local bstate = state.buffers[bufnr]
  if not bstate then
    return
  end

  stop_polling(bufnr)

  local timer = uv.new_timer()
  bstate.timer = timer
  timer:start(
    state.opts.poll_interval_ms,
    state.opts.poll_interval_ms,
    vim.schedule_wrap(function()
      poll_remote_revision(bufnr)
    end)
  )
end

local function save_buffer(bufnr)
  local bstate = state.buffers[bufnr]
  if not bstate then
    notify("Current buffer is not a HedgeDoc note", vim.log.levels.ERROR)
    return
  end

  if bstate.readonly then
    notify("Cannot save: note is read-only due to a remote update", vim.log.levels.ERROR)
    return
  end

  if bstate.saving then
    notify("Save already in progress", vim.log.levels.WARN)
    return
  end

  bstate.saving = true

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local content = table.concat(lines, "\n")
  local new_revision, err = save_document(bstate.doc_id, content, bstate.revision)
  bstate.saving = false

  if err then
    notify(string.format("Save failed for '%s': %s", bstate.doc_id, err), vim.log.levels.ERROR)
    return
  end

  if new_revision then
    bstate.revision = new_revision
    bstate.remote_revision = new_revision
  else
    bstate.revision = bstate.revision + 1
    bstate.remote_revision = bstate.revision
  end

  vim.bo[bufnr].modified = false
  notify(string.format("Saved '%s' (rev %d)", bstate.doc_id, bstate.revision), vim.log.levels.INFO)
end

local function parse_doc_id(input)
  local s = vim.trim(input or "")
  if s == "" then
    return nil
  end

  if s:match("^https?://") then
    local id = s:match("^https?://[^/]+/([^/?#]+)")
    if id then
      s = id
    end
  end

  s = s:gsub("%.md$", "")
  return s
end

function M.open(doc_ref)
  if state.opts.base_url == "" then
    notify("Set base_url in hedgedoc.setup({ base_url = ... })", vim.log.levels.ERROR)
    return
  end

  local doc_id = parse_doc_id(doc_ref)
  if not doc_id then
    notify("Usage: :HedgeDocOpen <note-id-or-url>", vim.log.levels.ERROR)
    return
  end

  local doc, err = fetch_document(doc_id)
  if err then
    notify(string.format("Open failed for '%s': %s", doc_id, err), vim.log.levels.ERROR)
    return
  end

  vim.cmd("enew")
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = split_lines_keep_empty(doc.content)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local buf_name = string.format("hedgedoc://%s.md", doc_id)
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
  vim.bo[bufnr].filetype = state.opts.filetype
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true

  state.buffers[bufnr] = {
    doc_id = doc_id,
    revision = doc.revision,
    saving = false,
    readonly = false,
    checking = false,
    refreshing = false,
    remote_revision = doc.revision,
    timer = nil,
  }

  start_polling(bufnr)
  notify(string.format("Opened '%s' (rev %d)", doc_id, doc.revision), vim.log.levels.INFO)
end

function M.setup(opts)
  state.opts = deep_merge(vim.deepcopy(defaults), opts or {})

  local aug = vim.api.nvim_create_augroup("HedgeDocNvim", { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = aug,
    pattern = "hedgedoc://*",
    callback = function(args)
      save_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = aug,
    pattern = "hedgedoc://*",
    callback = function(args)
      stop_polling(args.buf)
      state.buffers[args.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command("HedgeDocOpen", function(cmd)
    M.open(cmd.args)
  end, {
    nargs = 1,
    complete = "file",
  })

  vim.api.nvim_create_user_command("HedgeDocSave", function()
    save_buffer(vim.api.nvim_get_current_buf())
  end, { nargs = 0 })
end

return M
