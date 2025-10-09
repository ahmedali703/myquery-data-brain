-- AJAX callback Process in Oracle APEX Page
-- Process Name:DASH_GEN_INSIGHTS



DECLARE
  v_dash_id        NUMBER := TO_NUMBER(:P3_DASH_ID);
  v_done           NUMBER := 0;
  v_total          NUMBER := 0;
  l_out            CLOB;

  -- locals
  v_sql            CLOB;
  v_map            CLOB;
  v_chart          VARCHAR2(50);
  v_title          VARCHAR2(200);

  v_sample_json    CLOB;
  v_ai_json        CLOB;
  v_bullets_text   CLOB;
  v_all_insights   CLOB;

  -- HTTP helpers
  PROCEDURE set_json_headers IS
  BEGIN
    apex_web_service.g_request_headers.delete;
    apex_web_service.g_request_headers(1).name  := 'Content-Type';
    apex_web_service.g_request_headers(1).value := 'application/json';
  END;

  FUNCTION json_escape(p IN CLOB) RETURN CLOB IS
    l CLOB;
  BEGIN
    l := p;
    l := REPLACE(l, '\', '\\');
    l := REPLACE(l, '"', '\"');
    l := REPLACE(l, CHR(13), '\r');
    l := REPLACE(l, CHR(10), '\n');
    l := REPLACE(l, CHR(9),  '\t');
    RETURN l;
  END;

  -- stream CLOB to response
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

  -- turn insights JSON into bullet text
  FUNCTION json_insights_to_text(p_json CLOB) RETURN CLOB IS
    c CLOB := NULL;
  BEGIN
    FOR r IN (
      SELECT txt
      FROM JSON_TABLE(
             p_json,
             '$.insights[*]'
             COLUMNS ( txt VARCHAR2(4000) PATH '$' )
           )
    ) LOOP
      IF c IS NULL THEN c := TO_CLOB('• '||r.txt); ELSE c := c||CHR(10)||'• '||r.txt; END IF;
    END LOOP;
    RETURN NVL(c, TO_CLOB('No insights.'));
  EXCEPTION
    WHEN OTHERS THEN
      RETURN TO_CLOB('No insights.');
  END;

BEGIN
  IF v_dash_id IS NULL THEN
    apex_json.initialize_clob_output;
    apex_json.open_object; apex_json.write('ok', false); apex_json.write('error', 'P3_DASH_ID is NULL'); apex_json.close_object;
    l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out); RETURN;
  END IF;

  -- Get dashboard question and schema
  DECLARE
    v_question VARCHAR2(4000);
    v_schema   VARCHAR2(128) := :P0_DATABASE_SCHEMA;
  BEGIN
    SELECT name INTO v_question FROM dashboards WHERE id = v_dash_id;
    
    -- Build prompt for overall insights with schema context
    DECLARE
      l_prompt CLOB;
      l_body   CLOB;
      l_resp   CLOB;
    BEGIN
      l_prompt :=
        'You are a BI analyst. Generate 3-5 concrete business insights for this dashboard question. '||
        'Use schema: '||NVL(v_schema, 'default')||'. '||
        'Return JSON only: {"insights":["insight1","insight2",...]}. '||
        'Make insights specific, actionable, and business-focused.'||CHR(10)||
        'Question: '||v_question;

      l_body := '{"model":"gpt-4o-mini",'||
                '"response_format":{"type":"json_object"},'||
                '"temperature":0.2,'||
                '"messages":[{"role":"user","content":"'||json_escape(l_prompt)||'"}]}';

      set_json_headers;
      l_resp := APEX_WEB_SERVICE.make_rest_request(
                  p_url                  => 'https://api.openai.com/v1/chat/completions',
                  p_http_method          => 'POST',
                  p_body                 => l_body,
                  p_credential_static_id => 'credentials_for_ai_services'
                );

      IF APEX_WEB_SERVICE.g_status_code = 200 THEN
        SELECT JSON_VALUE(l_resp,'$.choices[0].message.content' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
          INTO v_ai_json
          FROM dual;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_ai_json := NULL;
    END;

    -- Convert to bullets
    IF v_ai_json IS NOT NULL THEN
      BEGIN
        v_all_insights := json_insights_to_text(v_ai_json);
        -- If parsing failed or returned empty, set fallback
        IF v_all_insights IS NULL OR v_all_insights = 'No insights.' THEN
          v_all_insights := TO_CLOB('AI generated insights but parsing failed. Raw: ' || DBMS_LOB.SUBSTR(v_ai_json, 1000));
        END IF;
      EXCEPTION
        WHEN OTHERS THEN
          v_all_insights := TO_CLOB('Error parsing insights: ' || SQLERRM || '. Raw: ' || DBMS_LOB.SUBSTR(v_ai_json, 1000));
      END;
    ELSE
      v_all_insights := TO_CLOB('No insights generated (null response from AI).');
    END IF;
  END;

  -- upsert single Key Insights widget near top
  DECLARE
    v_key_id NUMBER;
    v_ymin   NUMBER := 0;
  BEGIN
    -- find existing Key Insights
    BEGIN
      SELECT id INTO v_key_id
        FROM widgets
       WHERE dashboard_id = v_dash_id
         AND NVL(UPPER(chart_type),'TEXT') = 'TEXT'
         AND UPPER(title) LIKE 'KEY INSIGHTS%'
         AND ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_key_id := NULL; END;

    IF v_key_id IS NULL THEN
      -- place above first row of widgets
      SELECT NVL(MIN(grid_y),0) INTO v_ymin FROM widgets WHERE dashboard_id = v_dash_id;
      INSERT INTO widgets(
        dashboard_id, title, sql_query, chart_type, data_mapping, visual_options,
        grid_x, grid_y, grid_w, grid_h,
        refresh_mode, refresh_interval_sec, cache_ttl_sec,
        created_at, updated_at
      ) VALUES (
        v_dash_id,
        'Key Insights',
        TO_CLOB('SELECT ''' || REPLACE(DBMS_LOB.SUBSTR(NVL(v_all_insights,'No insights.'), 24000), '''', '''''') || ''' as insights_text FROM dual'),
        'TEXT',
        NULL,
        NULL,
        0, LEAST(0, v_ymin - 1), 12, 4,
        'MANUAL', 0, 0,
        SYSTIMESTAMP, SYSTIMESTAMP
      ) RETURNING id INTO v_key_id;
    ELSE
      UPDATE widgets
         SET visual_options = TO_CLOB('{"text":"' || REPLACE(DBMS_LOB.SUBSTR(NVL(v_all_insights,'No insights.'), 24000), '"','\"') || '"}'),
             updated_at     = SYSTIMESTAMP
       WHERE id = v_key_id;
    END IF;
  END;

  -- output
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', true);
    apex_json.write('dashboardId', v_dash_id);
    apex_json.write('insightsCreated', 1);
    apex_json.write('message', 'Key Insights generated by AI');
  apex_json.close_object;
  l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);

EXCEPTION
  WHEN OTHERS THEN
    apex_json.initialize_clob_output;
    apex_json.open_object; apex_json.write('ok', false); apex_json.write('error', SQLERRM); apex_json.close_object;
    l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);
END;
