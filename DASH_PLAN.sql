-- Ajax Callback in Oracle APEX
-- DASH_PLAN

DECLARE
  v_plan    CLOB;
  v_title   VARCHAR2(200);
  v_blocks  NUMBER := 0;
  n_ok      NUMBER := 0;       -- 1 if valid JSON
  ok_flag   VARCHAR2(1) := 'N';
  l_out     CLOB;

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
  -- Call planner
  myquery_dashboard_ai_pkg.plan_layout_and_blocks(
    p_question    => :P3_QUESTION,
    p_plan_json   => v_plan,
    p_schema      => :P0_DATABASE_SCHEMA,
    p_model       => 'gpt-5-2025-08-07',
    p_max_widgets => 6
  );

  -- Validate JSON
  IF v_plan IS NOT NULL THEN
    SELECT CASE WHEN JSON_EXISTS(v_plan,'$') THEN 1 ELSE 0 END
      INTO n_ok FROM dual;
  END IF;

  IF n_ok = 1 THEN
    SELECT JSON_VALUE(v_plan, '$.title' RETURNING VARCHAR2(200) NULL ON ERROR NULL ON EMPTY)
      INTO v_title FROM dual;

    SELECT COUNT(*)
      INTO v_blocks
      FROM JSON_TABLE(
             v_plan,
             '$.blocks[*]'
             COLUMNS ( dummy VARCHAR2(1) PATH '$.title' )
           );

    IF NVL(UPPER(v_title),'OK') <> 'ERROR' AND v_blocks > 0 THEN
      ok_flag := 'Y';
    END IF;
  END IF;

  IF ok_flag = 'Y' THEN
    -- Persist and emit success JSON
    APEX_UTIL.SET_SESSION_STATE('P3_PLAN_JSON', v_plan);

    apex_json.initialize_clob_output;
    apex_json.open_object;
      apex_json.write('ok', true);
      apex_json.write('title', NVL(v_title, 'AI Dashboard'));
      apex_json.write('blocksCount', v_blocks);
      apex_json.write('plan', v_plan);
    apex_json.close_object;
    l_out := apex_json.get_clob_output;
    apex_json.free_output;

    out_json(l_out);
    RETURN;
  END IF;

  -- Failure JSON (no persist)
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', false);
    apex_json.write('title', NVL(v_title, 'Error'));
    apex_json.write('blocksCount', v_blocks);
    apex_json.write('plan', NVL(v_plan, '{"title":"Error","layout":{"columns":12},"blocks":[]}'));
  apex_json.close_object;
  l_out := apex_json.get_clob_output;
  apex_json.free_output;

  out_json(l_out);

EXCEPTION
  WHEN OTHERS THEN
    apex_json.initialize_clob_output;
    apex_json.open_object;
      apex_json.write('ok', false);
      apex_json.write('error', SQLERRM);
    apex_json.close_object;
    l_out := apex_json.get_clob_output;
    apex_json.free_output;

    out_json(l_out);
END;
