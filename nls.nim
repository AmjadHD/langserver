import
  json_rpc/streamconnection,
  streams,
  os,
  faststreams/async_backend,
  faststreams/textio,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/asynctools_adapters


var pipe = createPipe(register = true)

proc serverThreadStart(pipe: AsyncPipe) {.thread.} =
  # var output = asyncPipeOutput(pipe = pipe, allowWaitFor = true);
  var
    inputStream = newFileStream(stdin)
    ch = "^"

  ch[0] = inputStream.readChar();
  while ch[0] != '\0':
    echo "|", ch, "|"
    discard write(pipe, ch[0].addr, 1)
    ch[0] = inputStream.readChar();
  # waitFor flushAsync(output)

proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  echo "|||||"
  return some(StringOfJson($params))

# proc readMessage(input: AsyncInputStream): Future[string] {.async.} =
#   if input.readable:
#     return await input.readLine();
#   return "NONE!!";

var stdioThread: Thread[AsyncPipe]
createThread(stdioThread, serverThreadStart, pipe)

# sleep(100)

let connection = StreamConnection.new(asyncPipeInput(pipe),
                                      Async(fileOutput(stdout)));
connection.register("echo", echo)
waitFor connection.start()
# echo "Exit"
