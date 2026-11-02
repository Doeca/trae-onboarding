# Native authorization URLs only. Values intentionally retain parse_qs arrays.
def unquote:
  gsub("\\+"; " ") | explode as $s |
  reduce range(0; $s|length) as $i ({out:[], skip:0};
    if .skip > 0 then .skip -= 1
    elif $s[$i] == 37 then
      ($s[$i+1:$i+3] | implode | ascii_downcase) as $hex |
      if ($hex | test("^[0-9a-f]{2}$")) then
        ($hex | explode | map(if . >= 97 then .-87 else .-48 end)) as $n |
        .out += [$n[0]*16+$n[1]] | .skip=2
      else error("invalid_escape") end
    else .out += [$s[$i]] end) | .out | implode;
def invalid: error("native_session_invalid");
[scan("https://www\\.trae\\.cn/authorization\\?[^\\s\u001b]+(?=[\\s\u001b])")] as $urls |
if ($urls|length)==0 then empty else $urls[0] end |
if length > 32768 or test("#") then invalid else . end |
ltrimstr("https://www.trae.cn/authorization?") | split("&") |
if length > 100 then invalid else . end |
reduce .[] as $field ({};
  ($field|index("=")) as $at |
  (if $at == null then [$field,""] else [$field[0:$at],$field[$at+1:]] end | map(unquote)) as $kv |
  .[$kv[0]] = ((.[$kv[0]] // []) + [$kv[1]])) |
. as $q |
if all(["device_id","x_device_id","login_trace_id","auth_callback_url"][];
       ($q[.]|length)==1 and ($q[.][0]|length)>0)
   and .device_id == .x_device_id
   and (.auth_callback_url[0] | test("^http://127\\.0\\.0\\.1:[0-9]{1,5}/authorize$"))
then . else invalid end |
(.auth_callback_url[0] | capture(":(?<port>[0-9]+)/authorize$").port | tonumber) as $port |
if $port > 0 and $port <= 65535 then . else invalid end
