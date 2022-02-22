import macros, strformat, faststreams/async_backend, itertools,
  faststreams/asynctools_adapters, faststreams/inputs, faststreams/outputs,
  json_rpc/streamconnection, os, sugar, sequtils, hashes, osproc,
  suggestapi, protocol/enums, protocol/types, with, tables, strutils, sets,
  ./utils, ./pipes, chronicles, std/re, uri, "$nim/compiler/pathutils"

const storage = getTempDir() / "nls"
discard existsOrCreateDir(storage)

type
  NlsNimsuggestConfig = ref object of RootObj
    root: string
    regexps: seq[string]

  NlsConfig = ref object of RootObj
    nimsuggest: seq[NlsNimsuggestConfig]

  LanguageServer* = ref object
    connection: StreamConnection
    projectFiles: Table[string, tuple[nimsuggest: Future[Nimsuggest],
                                      openFiles: OrderedSet[string]]]
    openFiles: Table[string, tuple[projectFile: string,
                                   fingerTable: seq[seq[tuple[u16pos, offset: int]]]]]
    clientCapabilities*: ClientCapabilities
    initializeParams*: InitializeParams
    workspaceConfiguration: Future[JsonNode]
    fileWithDiags: seq[string]

  Certainty = enum
    None,
    Folder,
    Cfg,
    Nimble

macro `%*`*(t: untyped, inputStream: untyped): untyped =
  result = newCall(bindSym("to", brOpen),
                   newCall(bindSym("%*", brOpen), inputStream), t)

proc partial*[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe.}, a: A):
    proc (b: B) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b)

proc getProjectFileAutoGuess(fileUri: string): string =
  let file = fileUri.decodeUrl
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = None
  while path.len > 0 and path != "/":
    let
      (dir, fname, ext) = path.splitFile()
      current = fname & ext
    if fileExists(path / current.addFileExt(".nim")) and certainty <= Folder:
      result = path / current.addFileExt(".nim")
      certainty = Folder
    if fileExists(path / current.addFileExt(".nim")) and
      (fileExists(path / current.addFileExt(".nim.cfg")) or
      fileExists(path / current.addFileExt(".nims"))) and certainty <= Cfg:
      result = path / current.addFileExt(".nim")
      certainty = Cfg
    if certainty <= Nimble:
      for nimble in walkFiles(path / "*.nimble"):
        let info = execProcess("nimble dump " & nimble)
        var sourceDir, name: string
        for line in info.splitLines:
          if line.startsWith("srcDir"):
            sourceDir = path / line[(1 + line.find '"')..^2]
          if line.startsWith("name"):
            name = line[(1 + line.find '"')..^2]
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and
            file.isRelativeTo(sourceDir) and fileExists(projectFile):
          debug "Found nimble project", projectFile = projectFile
          result = projectFile
          certainty = Nimble
    path = dir

proc getWorkspaceConfiguration(ls: LanguageServer): Future[NlsConfig] {.async} =
  try:
    let nlsConfig: seq[NlsConfig] =
      (%ls.workspaceConfiguration.await).to(seq[NlsConfig])
    result = if nlsConfig.len > 0: nlsConfig[0] else: NlsConfig()
  except CatchableError:
    debug "Failed to parse the configuration."
    result = NlsConfig()

proc getProjectFile(fileUri: string, ls: LanguageServer): Future[string] {.async} =
  logScope:
    uri = fileUri
  let
    rootPath = AbsoluteDir(ls.initializeParams.rootUri.uriToPath)
    pathRelativeToRoot = cstring(AbsoluteFile(fileUri).relativeTo(rootPath))
    cfgs = ls.getWorkspaceConfiguration.await.nimsuggest

  for cfg in cfgs:
    for regex in cfg.regexps:
      if find(pathRelativeToRoot, re(regex), 0, pathRelativeToRoot.len) != -1:
        result = string(rootPath) / cfg.root
        debug "getProjectFile", project = result
        return result

  result = getProjectFileAutoGuess(fileUri)
  debug "getProjectFile", project = result

proc getCharacter(ls: LanguageServer, uri: string, line: int, character: int): int =
  return ls.openFiles[uri].fingerTable[line].utf16to8(character)

proc initialize(ls: LanguageServer, params: InitializeParams):
    Future[InitializeResult] {.async} =
  debug "Initialize received..."
  ls.initializeParams = params
  return InitializeResult(
    capabilities: ServerCapabilities(
      textDocumentSync: some(%TextDocumentSyncOptions(
        openClose: some(true),
        change: some(TextDocumentSyncKind.Full.int),
        willSave: some(false),
        willSaveWaitUntil: some(false),
        save: some(SaveOptions(includeText: some(true))))),
      hoverProvider: some(true),
      workspace: WorkspaceCapability(workspaceFolders: some(WorkspaceFolderCapability())),
      completionProvider: CompletionOptions(
        triggerCharacters: some(@["."]),
        resolveProvider: some(false)),
      definitionProvider: some(true),
      referencesProvider: some(true),
      documentSymbolProvider: some(true)
      # renameProvider: some(true)
      ))

proc initialized(ls: LanguageServer, _: JsonNode):
    Future[void] {.async.} =
 debug "Client initialized."
 let workspaceCap = ls.initializeParams.capabilities.workspace
 if workspaceCap.isSome and workspaceCap.get.configuration.get(false):
    debug "Requesting configuration from the client"
    let configurationParams = ConfigurationParams %* {"items": [{"section": "nim"}]}

    ls.workspaceConfiguration =
      ls.connection.call("workspace/configuration",
                         %configurationParams)
 else:
   debug "Client does not support workspace/configuration"
   ls.workspaceConfiguration.complete(newJArray())

proc cancelRequest(params: CancelParams):
    Future[void] {.async} =
 debug "Cancelling", id = params.id

proc uriToStash(uri: string): string =
  storage / (hash(uri).toHex & ".nim")

template getNimsuggest(ls: LanguageServer, uri: string): Nimsuggest =
  ls.projectFiles[ls.openFiles[uri].projectFile].nimsuggest.await

proc toDiagnostic(suggest: Suggest): Diagnostic =
  with suggest:
    let endColumn = column + doc.rfind('\'') - doc.find('\'') - 1

    return Diagnostic %* {
      "uri": pathToUri(filepath),
      "range": {
         "start": {
            "line": line - 1,
            "character": column
         },
         "end": {
            "line": line - 1,
            "character": column + max(qualifiedPath[^1].len, endColumn)
         }
      },
      "severity": case forth:
                    of "Error": DiagnosticSeverity.Error.int
                    of "Hint": DiagnosticSeverity.Hint.int
                    of "Warning": DiagnosticSeverity.Warning.int
                    else: DiagnosticSeverity.Error.int,
      "message": doc,
      "source": "nim",
      "code": "nimsuggest chk"
    }

proc checkAllFiles(ls: LanguageServer, uri: string): Future[void] {.async} =
  let diagnostics = ls.getNimsuggest(uri)
    .chk(uriToPath(uri), uriToStash(uri))
    .await()
    .filter(sug => sug.filepath != "???")

  debug "Found diagnostics", files = diagnostics.map(s => s.filepath).deduplicate()
  for (path, diags) in groupBy(diagnostics, s => s.filepath):
    debug "Sending diagnostics", count = diags.len, path = path
    let params = PublishDiagnosticsParams %* {
      "uri": pathToUri(path),
      "diagnostics": diags.map(toDiagnostic)
    }
    ls.connection.notify("textDocument/publishDiagnostics", %params)

proc progressSupported(ls: LanguageServer): bool =
  result = ls.initializeParams.capabilities.window.get(WindowCapabilities()).workDoneProgress.get(false)

proc didOpen(ls: LanguageServer, params: DidOpenTextDocumentParams):
    Future[void] {.async, gcsafe.} =

   with params.textDocument:
     let
       fileStash = uriToStash(uri)
       file = open(fileStash, fmWrite)
       projectFile = await getProjectFile(uriToPath(uri), ls)

     debug "New document opened for URI:", uri = uri, fileStash = fileStash

     ls.openFiles[uri] = (
       projectFile: projectFile,
       fingerTable: @[])

     if not ls.projectFiles.hasKey(projectFile):
       let
         nimsuggestFut = createNimsuggest(projectFile)
         fileName = projectFile.AbsoluteFile().extractFileName()
         token = fmt "Creating nimsuggest for {projectFile}"

       ls.projectFiles[projectFile] = (nimsuggest: nimsuggestFut,
                                       openFiles: initOrderedSet[string]())

       if ls.progressSupported:
         discard ls.connection.call("window/workDoneProgress/create",
                                    %ProgressParams(token: token))

       if ls.progressSupported:
         ls.connection.notify(
           "$/progress",
           %* {
                "token": token,
                "value": {
                  "kind": "begin",
                  "title": fmt "Creating nimsuggest for {fileName}"
                }
           })
         proc cb (fut: Future[Nimsuggest]) =
           if fut.read.failed:
             ls.connection.notify(
               "window/showMessage",
               %* {
                    "type": MessageType.Error.int,
                    "message": fmt "Nimsuggest initialization for {projectFile} failed with: {fut.read.errorMessage}"
               })
           else:
             ls.connection.notify(
               "window/showMessage",
               %* {
                    "type": MessageType.Info.int,
                    "message": fmt "Nimsuggest initialized for {projectFile}"
               })
             discard ls.checkAllFiles(uri)

           ls.connection.notify(
             "$/progress",
             %* {
                  "token": token,
                  "value": {
                    "kind": "end",
                  }
             })
         nimsuggestFut.addCallback(cb)

     ls.projectFiles[projectFile].openFiles.incl(uri)


     for line in text.splitLines:
       ls.openFiles[uri].fingerTable.add line.createUTFMapping()
       file.writeLine line
     file.close()


proc didChange(ls: LanguageServer, params: DidChangeTextDocumentParams):
    Future[void] {.async, gcsafe.} =
   with params:
     let
       uri = textDocument.uri
       path = uriToPath(uri)
       fileStash = uriToStash(uri)
       file = open(fileStash, fmWrite)

     ls.openFiles[uri].fingerTable = @[]
     for line in contentChanges[0].text.splitLines:
       ls.openFiles[uri].fingerTable.add line.createUTFMapping()
       file.writeLine line
     file.close()

     discard ls.getNimsuggest(uri).mod(path, dirtyfile = filestash)

proc didSave(ls: LanguageServer, params: DidSaveTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  discard ls.checkAllFiles(params.textDocument.uri)

proc didClose(ls: LanguageServer, params: DidCloseTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  debug "Closed the following document:", uri = params.textDocument.uri

proc toMarkedStrings(suggest: Suggest): seq[MarkedStringOption] =
  var label = suggest.qualifiedPath.join(".")
  if suggest.forth != "":
    label &= ": " & suggest.forth

  result = @[
    MarkedStringOption %* {
       "language": "nim",
       "value": label
    }
  ]

  if suggest.doc != "":
    result.add MarkedStringOption %* {
       "language": "markdown",
       "value": suggest.doc
    }

proc hover(ls: LanguageServer, params: HoverParams):
    Future[Option[Hover]] {.async} =
  with (params.position, params.textDocument):
    let
      suggestions = await ls.getNimsuggest(uri).def(
        uriToPath(uri),
        uriToStash(uri),
        line + 1,
        ls.getCharacter(uri, line, character))
    if suggestions.len == 0:
      return none[Hover]();
    else:
      return some(Hover(contents: some(%toMarkedStrings(suggestions[0]))))

proc toLocation(suggest: Suggest): Location =
  with suggest:
    return Location %* {
      "uri": pathToUri(filepath),
      "range": {
         "start": {
            "line": line - 1,
            "character": column
         },
         "end": {
            "line": line - 1,
            "character": column + qualifiedPath[^1].len
         }
      }
    }

proc definition(ls: LanguageServer, params: TextDocumentPositionParams):
    Future[seq[Location]] {.async} =
  with (params.position, params.textDocument):
    return ls
      .getNimsuggest(uri)
      .def(uriToPath(uri),
           uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .await()
      .map(toLocation);

proc references(ls: LanguageServer, params: ReferenceParams):
    Future[seq[Location]] {.async} =
  with (params.position, params.textDocument, params.context):
    return ls
      .getNimsuggest(uri)
      .use(uriToPath(uri),
           uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .await()
      .filter(suggest => suggest.section != ideDef or includeDeclaration)
      .map(toLocation);

proc toCompletionItem(suggest: Suggest): CompletionItem =
  with suggest:
    return CompletionItem %* {
      "label": qualifiedPath[^1].strip(chars = {'`'}),
      "kind": nimSymToLSPKind(suggest).int,
      "documentation": doc,
      "detail": nimSymDetails(suggest)
    }

proc completion(ls: LanguageServer, params: CompletionParams):
    Future[seq[CompletionItem]] {.async} =
  with (params.position, params.textDocument):
    return ls
      .getNimsuggest(uri)
      .sug(uriToPath(uri),
           uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .await()
      .map(toCompletionItem);

proc toSymbolInformation(suggest: Suggest): SymbolInformation =
  with suggest:
    return SymbolInformation %* {
      "location": toLocation(suggest),
      "kind": nimSymToLSPSymbolKind(suggest.symKind).int,
      "name": suggest.name
    }


proc documentSymbols(ls: LanguageServer, params: DocumentSymbolParams):
    Future[seq[SymbolInformation]] {.async} =
  with (params.textDocument):
    return ls
      .getNimsuggest(uri)
      .outline(uriToPath(uri), uriToStash(uri))
      .await()
      .map(toSymbolInformation);

proc registerHandlers*(connection: StreamConnection) =
  let ls = LanguageServer(
    connection: connection,
    workspaceConfiguration: Future[JsonNode](),
    projectFiles: initTable[string,
                            tuple[nimsuggest: Future[Nimsuggest],
                                  openFiles: OrderedSet[string]]](),
    openFiles: initTable[string,
                         tuple[projectFile: string,
                               fingerTable: seq[seq[tuple[u16pos, offset: int]]]]]())
  connection.register("initialize", partial(initialize, ls))
  connection.register("textDocument/completion", partial(completion, ls))
  connection.register("textDocument/definition", partial(definition, ls))
  connection.register("textDocument/documentSymbol", partial(documentSymbols, ls))
  connection.register("textDocument/hover", partial(hover, ls))
  connection.register("textDocument/references", partial(references, ls))

  connection.registerNotification("$/cancelRequest", cancelRequest)
  connection.registerNotification("initialized", partial(initialized, ls))
  connection.registerNotification("textDocument/didChange", partial(didChange, ls))
  connection.registerNotification("textDocument/didOpen", partial(didOpen, ls))
  connection.registerNotification("textDocument/didSave", partial(didSave, ls))
  connection.registerNotification("textDocument/didClose", partial(didClose, ls))

when isMainModule:
  var
    pipe = createPipe(register = true, nonBlockingWrite = false)
    stdioThread: Thread[tuple[pipe: AsyncPipe, file: File]]

  createThread(stdioThread, copyFileToPipe, (pipe: pipe, file: stdin))

  let connection = StreamConnection.new(Async(fileOutput(stdout, allowAsyncOps = true)));
  registerHandlers(connection)
  waitFor connection.start(asyncPipeInput(pipe))
