-- AJAX callback Process in Oracle APEX Page
-- Process Name:DASH_CREATE_BLOCKS


DECLARE
  v_plan        CLOB := :P3_PLAN_JSON;
  v_question    VARCHAR2(4000) := :P3_QUESTION;
  v_schema      VARCHAR2(128) := :P0_DATABASE_SCHEMA;
  v_dash_title  VARCHAR2(1000);
  v_dash_id     NUMBER;
  l_out         CLOB;

  PROCEDURE out_json(p CLOB) IS
    pos  PLS_INTEGER := 1;
    len  PLS_INTEGER := DBMS_LOB.getlength(p);
  BEGIN
    owa_util.mime_header('application/json', FALSE);
    owa_util.http_header_close;
    WHILE pos <= len LOOP
      htp.prn(DBMS_LOB.SUBSTR(p, 32767, pos));
      pos := pos + 32767;
    END LOOP;
  END;

BEGIN
  IF v_plan IS NULL THEN
    apex_json.initialize_clob_output;
    apex_json.open_object;
      apex_json.write('ok', false);
      apex_json.write('error', 'P3_PLAN_JSON is NULL');
    apex_json.close_object;
    l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);
    RETURN;
  END IF;

  -- Always use user's question as dashboard title (for sidebar history)
  v_dash_title := SUBSTR(NVL(v_question, 'AI Dashboard'), 1, 1000);

  -- Create dashboard (no widgets for now - AI will generate description and insights)
  INSERT INTO DASHBOARDS (NAME, DESCRIPTION, IS_PUBLIC, CREATED_AT, UPDATED_AT)
  VALUES (v_dash_title, v_question, 'N', SYSTIMESTAMP, SYSTIMESTAMP)
  RETURNING ID INTO v_dash_id;

  -- Return success
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', true);
    apex_json.write('dashboardId', v_dash_id);
    apex_json.write('title', v_dash_title);
    apex_json.write('blocksCreated', 0);
    apex_json.write('message', 'Dashboard created. AI will generate overview and insights next.');
  apex_json.close_object;
  l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);

EXCEPTION
  WHEN OTHERS THEN
    apex_json.initialize_clob_output;
    apex_json.open_object;
      apex_json.write('ok', false);
      apex_json.write('error', SQLERRM);
    apex_json.close_object;
    l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);
END;

