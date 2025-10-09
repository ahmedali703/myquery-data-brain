-- AJAX Callback process in Oracle APEX Page
-- Process Name: GET_SIDE_MENU

declare
  l_json clob;
begin
  myquery_smart_query_pkg.get_side_menu_proc(
    p_user    => :APP_USER,
    p_chat_id => :P3_DASH_ID,
    p_json    => l_json
  );

  owa_util.mime_header('application/json', false);
  htp.p('Cache-Control: no-cache');
  owa_util.http_header_close;
  htp.prn(l_json);
end;





