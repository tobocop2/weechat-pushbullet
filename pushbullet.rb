# author: Olivier 'yazgoo' Abdesselam
# license: MIT
# home repository: https://github.com/yazgoo/weechat-pushbullet

require 'rubygems'
require 'presbeus'

$presbeus = Presbeus.new(false)
$buffers = {}

def send_sms(data, command, rc, out, err)
  data = JSON.parse(data)
  b = data["b"]
  input_data = data["input_data"]
  Weechat.print(b, ">\t#{input_data}")
  Weechat.print("", "send_sms: #{[data, command, rc, out, err]}")
  if rc.to_i > 0
    Weechat.print(b, ">\tfailed sending #{input_data} (rc: #{rc})")
  end
  return Weechat::WEECHAT_RC_OK
end

def send_stuff(data, b, input_data, req)
  Weechat.print("", "send_stuff(#{[data, b, input_data, req]})")
  args = h(req).merge({"postfields" => req[:payload].to_s, "post" => 1})
  Weechat.hook_process_hashtable(
    "url:#{req[:url]}", args, 120 * 1000, "send_sms", {b: b, input_data: input_data}.to_json)
  Weechat::WEECHAT_RC_OK
end

def buffer_input_cb(data, b, input_data)
  device = Weechat.buffer_get_string(b, "localvar_device")
  input_data.force_encoding('UTF-8')
  send_stuff(data, b, input_data, $presbeus.send_sms(device, data, input_data))
end

def buffer_input_push(data, b, input_data)
  input_data.force_encoding('UTF-8')
  send_stuff(data, b, input_data, $presbeus.push(input_data))
end

def buffer_close_cb(data, buffer)
  return Weechat::WEECHAT_RC_OK
end

def load_thread(b, command, rc, out, err)
  payload = JSON.parse(out)
  payload["thread"].reverse.each do |c|
    Weechat.print(b, "#{c["direction"] == "outgoing" ? ">" : "<"}\t#{c["body"]}")
  end if payload.key?("thread")
  return Weechat::WEECHAT_RC_OK
end

def reload_thread(data, b, args)
  address = Weechat.buffer_get_string(b, "localvar_address")
  device = Weechat.buffer_get_string(b, "localvar_device")
  req = $presbeus.get_v2("permanents/#{device}_thread_#{address}")
  Weechat.hook_process_hashtable(
    "url:#{req[:url]}", h(req), 120 * 1000, "load_thread", b)
  return Weechat::WEECHAT_RC_OK
end

def setup_thread(device, address, name)
  b = Weechat.buffer_new(name, 'buffer_input_cb', name, 'buffer_close_cb', name)
  $buffers[address] = b
  Weechat.buffer_set(b, "localvar_set_address", address)
  Weechat.buffer_set(b, "localvar_set_device", device)
  reload_thread(nil, b, nil)
end

def load_threads(device, command, rc, out, err)
  Weechat.print('', "loading device #{device}")
  JSON.parse(out)["threads"].map{|x| Presbeus.parse_thread(x)}.each do |address, name|
  Weechat.print('', "loading device #{device}, #{address}, #{name}")
    setup_thread(device, address, name)
  end
  return Weechat::WEECHAT_RC_OK
end

def get_devices(data, command, rc, out, err)
  Weechat.print('', "devices:")
  JSON.parse(out)["devices"].each { |d|  Weechat.print('', "#{d["iden"]} : #{d["model"]}") }
  return Weechat::WEECHAT_RC_OK
end

def get_pushes(data, command, rc, out, err)
  JSON.parse(out)["pushes"].reverse.map do |push|
    Weechat.print($buffers["pushes"], push["body"])
  end
  return Weechat::WEECHAT_RC_OK
end

def h req
  {"httpheader" => req[:headers].map { |a, b| "#{a}:#{b}" }.join("\n")}
end

def load_device(data, b, device)
  Weechat.print('', "loading treads for device #{$presbeus.default_device}")
  req = $presbeus.get_v2("permanents/#{device}_threads")
  Weechat.hook_process_hashtable(
    "url:#{req[:url]}", h(req), 120 * 1000, "load_threads", device)
end

def realtime(data, command, rc, out, err)
  Weechat.print("", "realtime: '#{out}'")
  if out != ""
    begin
      payload = JSON.parse(out)
      if payload["type"] == "push"
        notifications = payload["push"]["notifications"]
        notifications.each do |push|
          Weechat.print("", "print #{$buffers[push["thread_id"]]}, #{push}")
          buffer = $buffers[push["thread_id"]]
          if buffer.nil?
            # handle new thread
            id = push["thread_id"]
            # todo find user name
            setup_thread(payload["push"]["source_device_iden"], id, "unknown ##{id}")
          else
            Weechat.print(buffer, ">\t#{push["body"]}")
          end
        end if notifications
      end
    rescue JSON::ParserError => e
      Weechat.print("", "failed to decode: '#{out}' (#{e})")
    end
  end
  if err != ""
    Weechat.print("", "realtime err: #{err}")
  end
  if rc.to_i >= 0
    Weechat.print("", "realtime failed with #{rc}")
    Weechat.print("", "restarting realtime")
    Weechat.hook_process_hashtable("presbeus realtime_raw", 
                                   {"buffer_flush" => "1"}, 0, "realtime", "")
  end
  return Weechat::WEECHAT_RC_OK
end

def weechat_init
  Weechat.register('pushbullet',
                   'PushBullet', '1.0', 'GPL3', 'Pushbullet', '', '')
  Weechat.hook_command("pb_r", "reload pushbullet tread", "", "", "", "reload_thread", "")
  Weechat.hook_command("pb_d", "load device", "", "", "", "load_device", "")
  req = $presbeus.get_v2("devices")
  Weechat.hook_process_hashtable(
    "url:#{req[:url]}", h(req), 120 * 1000, "get_devices", "")
  $buffers["pushes"] = Weechat.buffer_new("pushes", 'buffer_input_push', "pushes", 'buffer_close_cb', "pushes") 
  req = $presbeus.get_v2("pushes")
  Weechat.hook_process_hashtable(
    "url:#{req[:url]}", h(req), 120 * 1000, "get_pushes", "")
  Weechat.print('', "launch '/pb_d <device_id>' to load device")
  if !$presbeus.default_device.nil?
    load_device(nil, nil, $presbeus.default_device)
    Weechat.hook_process_hashtable("presbeus realtime_raw", 
                                   {"buffer_flush" => "1"}, 0, "realtime", "")
  end
  return Weechat::WEECHAT_RC_OK
end
