require 'http_server'
require 'pp'

HTTPServer.run(lambda { |env|
  [ 200,
    {'Content-Type' => "text/plain"},
    [PP.pp({:thread => Thread.current, :env => env}, '')] ]
})
