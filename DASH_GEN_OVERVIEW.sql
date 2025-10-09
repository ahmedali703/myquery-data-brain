-- AJAX Callback process in Oracle APEX Page
-- Process Name: DASH_GEN_OVERVIEW

DECLARE
  v_dash_id     NUMBER := TO_NUMBER(NVL(NULLIF(:P3_DASH_ID, ''), NULLIF(APEX_APPLICATION.G_X01, '')));
  v_question    VARCHAR2(4000) := :P3_QUESTION;
  v_overview    CLOB;
  v_overview_id NUMBER;
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
  IF v_dash_id IS NULL THEN
    apex_json.initialize_clob_output;
    apex_json.open_object;
      apex_json.write('ok', false);
      apex_json.write('error', 'P3_DASH_ID is NULL');
    apex_json.close_object;
    l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);
    RETURN;
  END IF;

  -- Generate overview text using AI
  myquery_dashboard_ai_pkg.generate_overview_text(
    p_question => v_question,
    p_overview => v_overview,
    p_schema   => :P0_DATABASE_SCHEMA
  );

  -- Ensure we have overview text
  IF v_overview IS NULL THEN
    v_overview := 'AI-generated overview will appear here once the dashboard analysis is complete.';
  END IF;

  -- Create or update Overview widget
  DECLARE
    v_ypos NUMBER := 1;
    v_ymin NUMBER := 0;
  BEGIN
    -- Find existing Overview widget
    BEGIN
      SELECT id INTO v_overview_id
        FROM widgets
       WHERE dashboard_id = v_dash_id
         AND UPPER(NVL(chart_type,'TEXT')) = 'TEXT'
         AND UPPER(title) = 'OVERVIEW'
         AND ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_overview_id := NULL; END;

    IF v_overview_id IS NULL THEN
      -- place above first row of widgets
      SELECT NVL(MIN(grid_y),0) INTO v_ymin FROM widgets WHERE dashboard_id = v_dash_id;
      
      -- Create new Overview widget
      INSERT INTO widgets(
        dashboard_id, title, sql_query, chart_type, data_mapping, visual_options,
        grid_x, grid_y, grid_w, grid_h,
        refresh_mode, refresh_interval_sec, cache_ttl_sec,
        created_at, updated_at
      ) VALUES (
        v_dash_id,
        'Overview',
        TO_CLOB('SELECT ''' || REPLACE(NVL(v_overview,'No overview available.'), '''', '''''') || ''' as overview_text FROM dual'),
        'TEXT',
        NULL,
        TO_CLOB('{"text":"' || REPLACE(DBMS_LOB.SUBSTR(NVL(v_overview,'No overview.'), 24000), '"','\"') || '"}'),
        0, v_ymin - 1, 12, 4,
        'MANUAL', 0, 0,
        SYSTIMESTAMP, SYSTIMESTAMP
      ) RETURNING id INTO v_overview_id;
    ELSE
      -- Update existing Overview widget
      UPDATE widgets
         SET visual_options = TO_CLOB('{"text":"' || REPLACE(DBMS_LOB.SUBSTR(NVL(v_overview,'No overview.'), 24000), '"','\"') || '"}'),
             updated_at     = SYSTIMESTAMP
       WHERE id = v_overview_id;
    END IF;
  END;

  -- Return success
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', true);
    apex_json.write('dashboardId', v_dash_id);
    apex_json.write('overviewWidgetId', v_overview_id);
    apex_json.write('overviewLen', DBMS_LOB.getlength(v_overview));
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
