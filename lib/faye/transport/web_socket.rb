module Faye
  
  class Transport::WebSocket < Transport
    WEBSOCKET_TIMEOUT = 1
    
    UNCONNECTED       = 1
    CONNECTING        = 2
    CONNECTED         = 3
    
    include EventMachine::Deferrable
    
    def self.usable?(endpoint, &callback)
      connected  = false
      called     = false
      socket_url = endpoint.gsub(/^http(s?):/, 'ws\1:')
      socket     = Faye::WebSocket::Client.new(socket_url)
      
      socket.onopen = lambda do |event|
        connected = true
        socket.close
        callback.call(true)
        called = true
        socket = nil
      end
      
      notconnected = lambda do |*args|
        callback.call(false) unless called or connected
        called = true
      end
      
      socket.onclose = socket.onerror = notconnected
      EventMachine.add_timer(WEBSOCKET_TIMEOUT, &notconnected)
    end
    
    def batching?
      false
    end
    
    def request(messages, timeout = nil)
      @timeout  ||= timeout
      @messages ||= {}
      messages.each { |message| @messages[message['id']] = message }
      with_socket { |socket| socket.send(JSON.unparse(messages)) }
    end
    
    def with_socket(&resume)
      callback(&resume)
      connect
    end
    
    def close
      return if @closed
      @closed = true
      @socket.close if @socket
    end
    
    def connect
      return if @closed
      
      @state ||= UNCONNECTED
      return unless @state == UNCONNECTED
      
      @state = CONNECTING
      
      @socket = Faye::WebSocket::Client.new(@endpoint.gsub(/^http(s?):/, 'ws\1:'))
      
      @socket.onopen = lambda do |*args|
        @timeout = nil
        @state = CONNECTED
        set_deferred_status(:succeeded, @socket)
      end
      
      @socket.onmessage = lambda do |event|
        messages = [JSON.parse(event.data)].flatten
        messages.each { |message| @messages.delete(message['id']) }
        receive(messages)
      end
      
      @socket.onclose = lambda do |*args|
        was_connected = (@state == CONNECTED)
        set_deferred_status(:deferred)
        @state = UNCONNECTED
        @socket = nil
        
        if was_connected
          resend
        else
          EventMachine.add_timer(@timeout) { connect }
          @timeout = @timeout * 2
        end
      end
    end
    
    def resend
      request(@messages.values)
    end
  end
  
  Transport.register 'websocket', Transport::WebSocket
  
end
