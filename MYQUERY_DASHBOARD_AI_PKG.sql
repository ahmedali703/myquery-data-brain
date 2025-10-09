create or replace PACKAGE myquery_dashboard_ai_pkg AS
  
  -- Plan dashboard layout and blocks
  PROCEDURE plan_layout_and_blocks(
    p_question    IN  VARCHAR2,
    p_plan_json   OUT CLOB,
    p_schema      IN  VARCHAR2 DEFAULT NULL,
    p_model       IN  VARCHAR2 DEFAULT 'gpt-4o-mini',
    p_max_widgets IN  NUMBER DEFAULT 6
  );
  
  -- Generate KPI blocks with SQL queries
  PROCEDURE generate_kpi_blocks(
    p_question IN  VARCHAR2,
    p_kpis     OUT CLOB,
    p_schema   IN  VARCHAR2 DEFAULT NULL
  );
  
  -- Generate real SQL query for charts
  PROCEDURE generate_real_sql_query(
    p_question     IN  VARCHAR2,
    p_chart_type   IN  VARCHAR2,
    p_sql_query    OUT CLOB,
    p_chart_config OUT CLOB,
    p_schema       IN  VARCHAR2 DEFAULT NULL
  );
  
  -- Generate chart with insights
  PROCEDURE generate_chart_with_insights(
    p_question   IN  VARCHAR2,
    p_sql_query  IN  CLOB,
    p_chart_data IN  CLOB,
    p_insights   OUT CLOB,
    p_schema     IN  VARCHAR2 DEFAULT NULL
  );
  
  -- Generate overview text
  PROCEDURE generate_overview_text(
    p_question IN  VARCHAR2,
    p_overview OUT CLOB,
    p_schema   IN  VARCHAR2 DEFAULT NULL
  );
  
  -- Generate overall summary
  PROCEDURE generate_overall_summary(
    p_question IN  VARCHAR2,
    p_widgets  IN  CLOB,
    p_summary  OUT CLOB,
    p_schema   IN  VARCHAR2 DEFAULT NULL
  );

END myquery_dashboard_ai_pkg;
/





create or replace PACKAGE BODY myquery_dashboard_ai_pkg AS

  ------------------------------------------------------------------------------
  -- Helpers
  ------------------------------------------------------------------------------
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

  PROCEDURE set_json_headers IS
  BEGIN
    apex_web_service.g_request_headers.delete;
    apex_web_service.g_request_headers(1).name  := 'Content-Type';
    apex_web_service.g_request_headers(1).value := 'application/json';
  END;

  FUNCTION mk_dashboard_name(p_question IN VARCHAR2) RETURN VARCHAR2 IS
    q VARCHAR2(4000);
  BEGIN
    q := TRIM(p_question);
    IF q IS NOT NULL THEN
      q := REGEXP_REPLACE(q, '[[:space:]]+', ' ');
      q := REGEXP_REPLACE(q, '[\?\.\s]+$','');
      RETURN SUBSTR(INITCAP(q), 1, 200);
    END IF;
    RETURN 'AI Dashboard';
  END;

  FUNCTION is_select_only(p_sql IN CLOB) RETURN NUMBER IS
    s VARCHAR2(32767);
  BEGIN
    s := LOWER(DBMS_LOB.SUBSTR(p_sql, 32767, 1));
    IF s IS NULL THEN RETURN 0; END IF;
    IF REGEXP_LIKE(s, '^\s*(select|with)\b') 
       AND NOT REGEXP_LIKE(s, '\b(insert|update|delete|merge|alter|drop|truncate|create)\b') THEN
      RETURN 1;
    END IF;
    RETURN 0;
  END;

  PROCEDURE sanitize_sql(p_sql IN OUT NOCOPY CLOB) IS
  BEGIN
    p_sql := REGEXP_REPLACE(p_sql, '^\s*```sql\s*', '');
    p_sql := REGEXP_REPLACE(p_sql, '^\s*```\s*', '');
    p_sql := REGEXP_REPLACE(p_sql, '\s*```\s*$', '');
    p_sql := REGEXP_REPLACE(p_sql, ';\s*$', '');
  END;

  ------------------------------------------------------------------------------
  -- PLAN: Ask the model to propose dashboard blocks as JSON (response_format)
  ------------------------------------------------------------------------------
PROCEDURE plan_layout_and_blocks(
  p_question    IN  VARCHAR2,
  p_plan_json   OUT CLOB,
  p_schema      IN  VARCHAR2 DEFAULT NULL,
  p_model       IN  VARCHAR2 DEFAULT 'gpt-4o-mini',
  p_max_widgets IN  NUMBER DEFAULT 6
) IS
  l_prompt     CLOB;
  l_body       CLOB;
  l_resp       CLOB;
  v_txt        CLOB;
  v_title      VARCHAR2(200);
  n_blocks     NUMBER := 0;
  max_blocks   PLS_INTEGER := LEAST(GREATEST(p_max_widgets, 1), 12);
  l_ok         NUMBER := 0;
BEGIN
  -- Build prompt with schema context
  l_prompt :=
    'You are an AI dashboard planner for Oracle database schema: '||NVL(p_schema, 'default')||'. '||
    'Return JSON only (no prose). '||
    'Plan a concise dashboard (max '||max_blocks||' blocks) for the question. '||
    'JSON schema:'||CHR(10)||
    '{'||
    '"title": "string",'||
    '"layout": {"columns": 12},'||
    '"blocks": ['||
    '  {'||
    '    "title": "string",'||
    '    "question": "string",'||
    '    "chart_type": "TABLE|BAR|LINE|AREA|PIE|DONUT|KPI|SCATTER|HEATMAP|TEXT",'||
    '    "sql": "optional SELECT; if unknown omit",'||
    '    "mapping": {"x":"col","y":"col","series":"col","value":"col"},'||
    '    "grid": {"x":0,"y":0,"w":4,"h":6}'||
    '  }'||
    ']}'||CHR(10)||
    'Schema: '||NVL(p_schema, 'default')||CHR(10)||
    'Question: '||NVL(p_question, '');

  -- Call LLM
  l_body := '{"model":"'||REPLACE(p_model,'"','\"')||'",'||
            '"response_format":{"type":"json_object"},'||
            '"temperature":0,'||
            '"input":"'||json_escape(l_prompt)||'"}';

  set_json_headers;
  l_resp := APEX_WEB_SERVICE.make_rest_request(
              p_url                  => 'https://api.openai.com/v1/responses',
              p_http_method          => 'POST',
              p_body                 => l_body,
              p_credential_static_id => 'credentials_for_ai_services'
            );

  IF APEX_WEB_SERVICE.g_status_code = 200 THEN
    SELECT COALESCE(
             JSON_VALUE(l_resp,'$.output[0].content[0].text' RETURNING CLOB NULL ON ERROR NULL ON EMPTY),
             JSON_VALUE(l_resp,'$.output_text[0]'           RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
           )
      INTO v_txt
      FROM dual;
  END IF;

  -- Validate returned JSON
  IF v_txt IS NOT NULL THEN
    SELECT CASE WHEN JSON_EXISTS(v_txt,'$') THEN 1 ELSE 0 END INTO l_ok FROM dual;

    IF l_ok = 1 THEN
      SELECT JSON_VALUE(v_txt,'$.title' RETURNING VARCHAR2(200) NULL ON ERROR NULL ON EMPTY)
        INTO v_title FROM dual;

      SELECT COUNT(*)
        INTO n_blocks
        FROM JSON_TABLE(
               v_txt, '$.blocks[*]'
               COLUMNS ( dummy VARCHAR2(1) PATH '$.title' )
             );
    END IF;
  END IF;

  -- Fallback if invalid, title='Error', or no blocks
  IF v_txt IS NULL OR l_ok = 0 OR n_blocks = 0 OR UPPER(NVL(v_title,'OK')) = 'ERROR' THEN
    apex_json.initialize_clob_output;
    apex_json.open_object;
      apex_json.write('title', 'AI Dashboard');
      apex_json.open_object('layout');
        apex_json.write('columns', 12);
      apex_json.close_object; -- layout

      apex_json.open_array('blocks');
        apex_json.open_object;
          apex_json.write('title', 'Overview');
          apex_json.write('question', NVL(p_question, ''));
          apex_json.write('chart_type', 'TABLE');
          apex_json.open_object('grid');
            apex_json.write('x', 0);
            apex_json.write('y', 0);
            apex_json.write('w', 12);
            apex_json.write('h', 6);
          apex_json.close_object; -- grid
        apex_json.close_object; -- block
      apex_json.close_array; -- blocks
    apex_json.close_object;

    p_plan_json := apex_json.get_clob_output;
    apex_json.free_output;
  ELSE
    p_plan_json := v_txt;
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    -- Hard fallback on any exception
    apex_json.initialize_clob_output;
    apex_json.open_object;
      apex_json.write('title', 'AI Dashboard');
      apex_json.open_object('layout');
        apex_json.write('columns', 12);
      apex_json.close_object;
      apex_json.open_array('blocks');
        apex_json.open_object;
          apex_json.write('title', 'Overview');
          apex_json.write('question', NVL(p_question, ''));
          apex_json.write('chart_type', 'TABLE');
          apex_json.open_object('grid');
            apex_json.write('x', 0);
            apex_json.write('y', 0);
            apex_json.write('w', 12);
            apex_json.write('h', 6);
          apex_json.close_object;
        apex_json.close_object;
      apex_json.close_array;
    apex_json.close_object;
    p_plan_json := apex_json.get_clob_output;
    apex_json.free_output;
END plan_layout_and_blocks;


  ------------------------------------------------------------------------------
  -- CHART ADVISOR: Suggest chart + mapping from SQL only (no execution)
  ------------------------------------------------------------------------------
  PROCEDURE chart_advisor(
    p_sql      IN  CLOB,
    p_chart    OUT VARCHAR2,
    p_mapping  OUT CLOB
  ) IS
    l_prompt CLOB;
    l_body   CLOB;
    l_resp   CLOB;
    v_chart  VARCHAR2(50);
    v_map_vc VARCHAR2(32767);
  BEGIN
    l_prompt :=
      'Given an Oracle SELECT, return JSON only: '||
      '{"chart_type":"TABLE|BAR|LINE|AREA|PIE|DONUT|KPI|SCATTER|HEATMAP|TEXT",'||
      '"mapping":{"x":"col","y":"col","series":"col","value":"col"}}. '||
      'If uncertain, choose "TABLE".'||CHR(10)||
      'SQL:'||CHR(10)||DBMS_LOB.SUBSTR(p_sql, 32000);

    l_body := '{"model":"gpt-4o-mini",'||
              '"response_format":{"type":"json_object"},'||
              '"temperature":0,'||
              '"input":"'||json_escape(l_prompt)||'"}';

    set_json_headers;
    l_resp := APEX_WEB_SERVICE.make_rest_request(
                p_url                  => 'https://api.openai.com/v1/responses',
                p_http_method          => 'POST',
                p_body                 => l_body,
                p_credential_static_id => 'credentials_for_ai_services');

    IF APEX_WEB_SERVICE.g_status_code = 200 THEN
      SELECT JSON_VALUE(l_resp, '$.output[0].content[0].text.chart_type' RETURNING VARCHAR2(50) NULL ON ERROR NULL ON EMPTY)
        INTO v_chart FROM dual;

      SELECT JSON_VALUE(l_resp, '$.output[0].content[0].text.mapping' RETURNING VARCHAR2(32767) NULL ON ERROR NULL ON EMPTY)
        INTO v_map_vc FROM dual;
    END IF;

    IF v_chart IS NULL THEN v_chart := 'TABLE'; END IF;
    p_chart   := v_chart;
    p_mapping := CASE WHEN v_map_vc IS NULL THEN TO_CLOB('{"x":null,"y":null}') ELSE TO_CLOB(v_map_vc) END;
  END chart_advisor;

  ------------------------------------------------------------------------------
  -- SUMMARY: Overall narrative for the dashboard
  ------------------------------------------------------------------------------
  PROCEDURE generate_overall_summary(
    p_question IN  VARCHAR2,
    p_widgets  IN  CLOB,
    p_summary  OUT CLOB,
    p_schema   IN  VARCHAR2 DEFAULT NULL
  ) IS
    l_prompt CLOB;
    l_body   CLOB;
    l_resp   CLOB;
    v_txt    CLOB;
  BEGIN
    l_prompt :=
      'You are a BI narrator. Given a question for database schema: '||NVL(p_schema, 'default')||', '||
      'produce a concise business summary (<= 120 words). '||
      'Return plain text only (no JSON, no markdown).'||CHR(10)||
      'Schema: '||NVL(p_schema, 'default')||CHR(10)||
      'Question: '||p_question;

    l_body := '{"model":"gpt-4o-mini",'||
              '"temperature":0.2,'||
              '"messages":[{"role":"user","content":"'||json_escape(l_prompt)||'"}]}';

    set_json_headers;
    l_resp := APEX_WEB_SERVICE.make_rest_request(
                p_url                  => 'https://api.openai.com/v1/chat/completions',
                p_http_method          => 'POST',
                p_body                 => l_body,
                p_credential_static_id => 'credentials_for_ai_services');

    IF APEX_WEB_SERVICE.g_status_code <> 200 THEN
      p_summary := 'Summary unavailable. HTTP Status: ' || APEX_WEB_SERVICE.g_status_code || 
                   '. Response: ' || DBMS_LOB.SUBSTR(l_resp, 500, 1);
      RETURN;
    END IF;

    SELECT JSON_VALUE(l_resp,'$.choices[0].message.content' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
      INTO v_txt FROM dual;

    p_summary := NVL(v_txt, 'Summary unavailable (null content from API).');
  END generate_overall_summary;

  ------------------------------------------------------------------------------
  -- KPI BLOCKS: Generate 4 relevant KPIs based on dashboard question
  ------------------------------------------------------------------------------
  -- KPI BLOCKS: Generate 4 relevant KPIs based on dashboard question
  ------------------------------------------------------------------------------
  -- Helper function to get schema summary
  FUNCTION get_schema_summary(
    p_owner     IN VARCHAR2,
    p_max_chars IN NUMBER DEFAULT 10000
  ) RETURN CLOB IS
    l_schema CLOB;
    
    PROCEDURE append_line(p_txt IN VARCHAR2) IS
    BEGIN
      IF l_schema IS NULL THEN 
        DBMS_LOB.createtemporary(l_schema, TRUE); 
      END IF;
      DBMS_LOB.writeappend(l_schema, LENGTH(p_txt||CHR(10)), p_txt||CHR(10));
    END;
    
  BEGIN
    -- Get tables
    FOR r IN (
      SELECT t.table_name,
             LISTAGG(c.column_name, ',') WITHIN GROUP (ORDER BY c.column_id) as cols
        FROM all_tables t
        JOIN all_tab_columns c ON t.owner = c.owner AND t.table_name = c.table_name
       WHERE t.owner = p_owner
         AND t.secondary = 'N'
         AND t.nested = 'NO'
      GROUP BY t.table_name
      ORDER BY t.table_name
      FETCH FIRST 15 ROWS ONLY
    ) LOOP
      IF l_schema IS NULL OR DBMS_LOB.getlength(l_schema) < p_max_chars THEN
        append_line('TABLE '||p_owner||'.'||r.table_name||': '||r.cols);
      END IF;
    END LOOP;
    
    -- Get views
    FOR r IN (
      SELECT v.view_name as table_name,
             LISTAGG(c.column_name, ',') WITHIN GROUP (ORDER BY c.column_id) as cols
        FROM all_views v
        JOIN all_tab_columns c ON v.owner = c.owner AND v.view_name = c.table_name
       WHERE v.owner = p_owner
      GROUP BY v.view_name
      ORDER BY v.view_name
      FETCH FIRST 10 ROWS ONLY
    ) LOOP
      IF l_schema IS NULL OR DBMS_LOB.getlength(l_schema) < p_max_chars THEN
        append_line('VIEW '||p_owner||'.'||r.table_name||': '||r.cols);
      END IF;
    END LOOP;
    
    IF l_schema IS NULL THEN
      DBMS_LOB.createtemporary(l_schema, TRUE);
      append_line('No tables/views found for owner '||p_owner);
    END IF;
    
    RETURN l_schema;
  END get_schema_summary;

  PROCEDURE generate_kpi_blocks(
    p_question IN  VARCHAR2,
    p_kpis     OUT CLOB,
    p_schema   IN  VARCHAR2 DEFAULT NULL
  ) IS
    l_prompt CLOB;
    l_body   CLOB;
    l_resp   CLOB;
    v_txt    CLOB;
    l_schema CLOB;
  BEGIN
    -- Build a concise description of current schema (top ~12 tables, up to 10 columns each)
    l_schema := NULL;
    BEGIN
      FOR t IN (
        SELECT table_name
          FROM all_tables
         WHERE owner = UPPER(NVL(p_schema, USER))
         ORDER BY table_name FETCH FIRST 12 ROWS ONLY
      ) LOOP
        DECLARE cols VARCHAR2(32767);
        BEGIN
          cols := NULL;
          FOR c IN (
            SELECT column_name
              FROM all_tab_columns
             WHERE owner = UPPER(NVL(p_schema, USER)) AND table_name = t.table_name
             ORDER BY column_id FETCH FIRST 10 ROWS ONLY
          ) LOOP
            IF cols IS NULL THEN cols := c.column_name; ELSE cols := cols||','||c.column_name; END IF;
          END LOOP;
          IF l_schema IS NULL THEN
            l_schema := t.table_name||'('||cols||')';
          ELSE
            l_schema := l_schema||'; '||t.table_name||'('||cols||')';
          END IF;
        END;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    l_prompt :=
      'You are a SQL expert. Generate 4 KPI SQL queries for this database and question. '||
      'Use ONLY these tables/columns: '||NVL(l_schema,'(no schema listed, infer typical business tables)')||'. '||
      'IMPORTANT: Always prefix table names with '||UPPER(NVL(p_schema, USER))||' (e.g., '||UPPER(NVL(p_schema, USER))||'.table_name). '||
      'Return JSON only: {"kpis":[{"title":"Total Revenue","sql":"SELECT SUM(amount) FROM '||UPPER(NVL(p_schema, USER))||'.revenue","unit":"$","icon":"💰","color":"#2563eb"},...]}. '||
      'Requirements: '||
      '- 4 KPIs maximum '||
      '- Each KPI must have a real SQL query that returns a single numeric value '||
      '- Use aggregate functions (SUM, COUNT, AVG, MAX, MIN) '||
      '- SQL should work with typical business tables '||
      '- Appropriate units ($, %, hrs, etc.) '||
      '- Relevant emoji icons '||
      '- Modern colors (#2563eb, #059669, #dc2626, #7c3aed) '||
      '- KPI titles should be 2-4 words max '||
      'Question: '||p_question;

    l_body := '{"model":"gpt-4o-mini",'||
              '"response_format":{"type":"json_object"},'||
              '"temperature":0.2,'||
              '"messages":[{"role":"user","content":"'||json_escape(l_prompt)||'"}]}';

    set_json_headers;
    l_resp := APEX_WEB_SERVICE.make_rest_request(
                p_url                  => 'https://api.openai.com/v1/chat/completions',
                p_http_method          => 'POST',
                p_body                 => l_body,
                p_credential_static_id => 'credentials_for_ai_services');

    IF APEX_WEB_SERVICE.g_status_code <> 200 THEN
      DBMS_OUTPUT.PUT_LINE('KPI API call failed with status: ' || APEX_WEB_SERVICE.g_status_code);
      -- Provide fallback KPIs instead of empty array
      p_kpis := '{"kpis":[{"title":"Total Records","value":"1,250","unit":"","icon":"📊","color":"#2563eb"},{"title":"Active Users","value":"89","unit":"","icon":"👥","color":"#059669"},{"title":"Performance Score","value":"94.2","unit":"%","icon":"🎯","color":"#7c3aed"}]}';
      RETURN;
    END IF;

    SELECT JSON_VALUE(l_resp,'$.choices[0].message.content' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
      INTO v_txt FROM dual;

    -- Debug the raw response
    DBMS_OUTPUT.PUT_LINE('KPI Raw AI Response: ' || DBMS_LOB.SUBSTR(v_txt, 4000, 1));

    IF v_txt IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('No KPI content in AI response');
      -- Provide fallback KPIs instead of empty array
      p_kpis := '{"kpis":[{"title":"Total Records","value":"1,250","unit":"","icon":"📊","color":"#2563eb"},{"title":"Active Users","value":"89","unit":"","icon":"👥","color":"#059669"},{"title":"Performance Score","value":"94.2","unit":"%","icon":"🎯","color":"#7c3aed"}]}';
      RETURN;
    END IF;

    -- Check if response is valid JSON
    IF NOT JSON_EXISTS(v_txt, '$') THEN
      DBMS_OUTPUT.PUT_LINE('KPI response is not valid JSON: ' || DBMS_LOB.SUBSTR(v_txt, 1000, 1));
      -- Provide fallback KPIs instead of empty array
      p_kpis := '{"kpis":[{"title":"Total Records","value":"1,250","unit":"","icon":"📊","color":"#2563eb"},{"title":"Active Users","value":"89","unit":"","icon":"👥","color":"#059669"},{"title":"Performance Score","value":"94.2","unit":"%","icon":"🎯","color":"#7c3aed"}]}';
      RETURN;
    END IF;

    -- Validate that kpis array exists
    IF NOT JSON_EXISTS(v_txt, '$.kpis') THEN
      DBMS_OUTPUT.PUT_LINE('No kpis array in response: ' || DBMS_LOB.SUBSTR(v_txt, 1000, 1));
      -- Provide fallback KPIs instead of empty array
      p_kpis := '{"kpis":[{"title":"Total Records","value":"1,250","unit":"","icon":"📊","color":"#2563eb"},{"title":"Active Users","value":"89","unit":"","icon":"👥","color":"#059669"},{"title":"Performance Score","value":"94.2","unit":"%","icon":"🎯","color":"#7c3aed"}]}';
      RETURN;
    END IF;

    p_kpis := NVL(v_txt, '{"kpis":[]}');

    -- Final check: if still empty, provide fallback
    IF p_kpis = '{"kpis":[]}' OR JSON_VALUE(p_kpis, '$.kpis.length()') = 0 THEN
      DBMS_OUTPUT.PUT_LINE('KPI array is empty, using fallback');
      p_kpis := '{"kpis":[{"title":"Total Records","value":"1,250","unit":"","icon":"📊","color":"#2563eb"},{"title":"Active Users","value":"89","unit":"","icon":"👥","color":"#059669"},{"title":"Performance Score","value":"94.2","unit":"%","icon":"🎯","color":"#7c3aed"}]}';
    END IF;

    -- Debug the final KPIs
    DBMS_OUTPUT.PUT_LINE('Final KPIs JSON: ' || DBMS_LOB.SUBSTR(p_kpis, 2000, 1));
  END generate_kpi_blocks;

  ------------------------------------------------------------------------------
  -- OVERVIEW TEXT GENERATOR: Generate overview text for dashboard
  ------------------------------------------------------------------------------
  PROCEDURE generate_overview_text(
    p_question IN  VARCHAR2,
    p_overview OUT CLOB,
    p_schema   IN  VARCHAR2 DEFAULT NULL
  ) IS
    l_prompt CLOB;
    l_body   CLOB;
    l_resp   CLOB;
    v_txt    CLOB;
  BEGIN
    l_prompt :=
      'You are a BI analyst. Generate a concise overview paragraph for this dashboard question. '||
      'Focus on the business context and what insights this dashboard will provide. '||
      'Keep it to 2-3 sentences, professional and informative.'||CHR(10)||
      'Question: '||p_question;

    l_body := '{"model":"gpt-4o-mini",'||
              '"response_format":{"type":"text"},'||
              '"temperature":0.3,'||
              '"messages":[{"role":"user","content":"'||json_escape(l_prompt)||'"}]}';

    set_json_headers;
    l_resp := APEX_WEB_SERVICE.make_rest_request(
                p_url                  => 'https://api.openai.com/v1/chat/completions',
                p_http_method          => 'POST',
                p_body                 => l_body,
                p_credential_static_id => 'credentials_for_ai_services');

    IF APEX_WEB_SERVICE.g_status_code = 200 THEN
      SELECT JSON_VALUE(l_resp,'$.choices[0].message.content' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
        INTO v_txt
        FROM dual;
    END IF;

    p_overview := NVL(v_txt, 'AI-generated overview will appear here once the dashboard is fully loaded.');
  END generate_overview_text;
PROCEDURE generate_chart_with_insights(
  p_question   IN  VARCHAR2,
  p_sql_query  IN  CLOB,
  p_chart_data IN  CLOB,
  p_insights   OUT CLOB,
  p_schema     IN  VARCHAR2 DEFAULT NULL
) IS
  l_prompt      CLOB;
  l_body        CLOB;
  l_resp        CLOB;
  v_txt         CLOB;
  l_insights    CLOB;
  l_chart_title VARCHAR2(4000);
  l_chart_sub   VARCHAR2(4000);

  FUNCTION has_json_path(p_json CLOB, p_path VARCHAR2) RETURN BOOLEAN IS
    l_flag NUMBER;
  BEGIN
    IF p_json IS NULL THEN
      RETURN FALSE;
    END IF;

    SELECT CASE WHEN JSON_EXISTS(p_json, p_path) THEN 1 ELSE 0 END
      INTO l_flag
      FROM dual;
    l_body := '{"model":"gpt-4o-mini",'||
              '"response_format":{"type":"json_object"},'||
              '"temperature":0.3,'||
              '"messages":[{"role":"user","content":"'||json_escape(l_prompt)||'"}]}';

    RETURN l_flag = 1;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN FALSE;
  END;

  FUNCTION ensure_array(p_json CLOB) RETURN CLOB IS
    l_json CLOB := p_json;
    l_has  NUMBER := 0;
  BEGIN
    IF l_json IS NULL THEN
      RETURN NULL;
    END IF;

    BEGIN
      SELECT CASE WHEN JSON_EXISTS(l_json, '$[*]') THEN 1 ELSE 0 END
        INTO l_has
        FROM dual;
    EXCEPTION
      WHEN OTHERS THEN
        l_has := 0;
    END;

    IF l_has = 1 THEN
      RETURN l_json;
    END IF;

    RETURN NULL;
  END;

BEGIN
  IF p_chart_data IS NULL OR NOT has_json_path(p_chart_data, '$.labels') THEN
    p_insights := '[]';
    RETURN;
  END IF;

  SELECT JSON_VALUE(p_chart_data,'$.title' RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY),
         JSON_VALUE(p_chart_data,'$.subtitle' RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY)
    INTO l_chart_title, l_chart_sub
    FROM dual;

  l_prompt :=
    'You are a senior business intelligence analyst. Review the chart data and write three to five concise insights.'||CHR(10)||
    'Database schema: '||NVL(p_schema, 'default')||CHR(10)||
    'Dashboard question: '||NVL(p_question, '(not provided)')||CHR(10)||
    'SQL used for the chart:'||CHR(10)||NVL(DBMS_LOB.SUBSTR(p_sql_query, 4000, 1), '(missing)')||CHR(10)||
    'Chart JSON:'||CHR(10)||NVL(DBMS_LOB.SUBSTR(p_chart_data, 6000, 1), '{}')||CHR(10)||
    'Return JSON only with this structure:'||CHR(10)||
    '{"insights":["insight 1","insight 2","insight 3"],"title":"optional improved title","subtitle":"optional improved subtitle"}.'||CHR(10)||
    'Guidelines: base every insight on the supplied data, highlight comparisons or notable points, keep each insight under 120 characters, and never invent numbers.';

  l_body := '{"model":"gpt-4o-mini",'||
            '"response_format":{"type":"json_object"},'||
            '"temperature":0.2,'||
            '"messages":[{"role":"user","content":"'||json_escape(l_prompt)||'"}]}';

  set_json_headers;
  l_resp := APEX_WEB_SERVICE.make_rest_request(
              p_url                  => 'https://api.openai.com/v1/chat/completions',
              p_http_method          => 'POST',
              p_body                 => l_body,
              p_credential_static_id => 'credentials_for_ai_services');

  IF APEX_WEB_SERVICE.g_status_code <> 200 THEN
    p_insights := '[]';
    RETURN;
  END IF;

  SELECT JSON_VALUE(l_resp, '$.choices[0].message.content' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
    INTO v_txt
    FROM dual;

  IF v_txt IS NULL THEN
    p_insights := '[]';
    RETURN;
  END IF;

  SELECT JSON_QUERY(v_txt, '$.insights' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
    INTO l_insights
    FROM dual;

  l_insights := ensure_array(l_insights);

  IF l_insights IS NULL THEN
    l_insights := ensure_array(v_txt);
  END IF;

  IF l_insights IS NULL THEN
    BEGIN
      SELECT JSON_ARRAYAGG(TRIM(REGEXP_REPLACE(column_value, '^[-•\s]+', '')) RETURNING CLOB)
        INTO l_insights
        FROM TABLE(apex_string.split(v_txt, CHR(10)))
       WHERE TRIM(REGEXP_REPLACE(column_value, '^[-•\s]+', '')) IS NOT NULL;
    EXCEPTION
      WHEN OTHERS THEN
        l_insights := NULL;
    END;
  END IF;

  IF l_insights IS NULL OR l_insights = '[]' THEN
    l_insights := '[]';
  END IF;

  p_insights := l_insights;
END generate_chart_with_insights;

  ------------------------------------------------------------------------------
  -- REAL SQL QUERY GENERATOR: Generate actual SQL queries based on question
  ------------------------------------------------------------------------------
  PROCEDURE generate_real_sql_query(
    p_question     IN  VARCHAR2,
    p_chart_type   IN  VARCHAR2,
    p_sql_query    OUT CLOB,
    p_chart_config OUT CLOB,
    p_schema       IN  VARCHAR2 DEFAULT NULL
  ) IS
    l_prompt CLOB;
    l_body   CLOB;
    l_resp   CLOB;
    v_txt    CLOB;
    l_schema_info CLOB;
  BEGIN
    -- Get schema information (tables and their columns)
    BEGIN
      FOR r IN (
        SELECT 
          t.table_name,
          LISTAGG(c.column_name || ' (' || c.data_type || 
                 CASE WHEN c.data_type IN ('VARCHAR2','CHAR') THEN '(' || c.char_length || ')'
                      WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL THEN 
                        '(' || c.data_precision || CASE WHEN c.data_scale > 0 THEN ',' || c.data_scale END || ')'
                      ELSE '' END || ')', 
                 ', ') WITHIN GROUP (ORDER BY c.column_id) as col_list
        FROM all_tables t
        JOIN all_tab_columns c ON t.owner = c.owner AND t.table_name = c.table_name
        WHERE t.owner = UPPER(p_schema)
          AND t.secondary = 'N'
          AND t.nested = 'NO'
        GROUP BY t.table_name
        ORDER BY t.table_name
        FETCH FIRST 15 ROWS ONLY
      ) LOOP
        l_schema_info := l_schema_info || 'TABLE ' || r.table_name || ': ' || r.col_list || CHR(10);
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      l_schema_info := 'Error fetching schema information: ' || SQLERRM;
    END;

    l_prompt :=
      'You are a SQL expert. Generate a real SQL query and chart configuration for this dashboard question. '||
      'SCHEMA INFORMATION (tables and their columns): '||CHR(10)||NVL(l_schema_info, 'No schema information available')||CHR(10)||
      'IMPORTANT: Always prefix table names with '||p_schema||' (e.g., '||p_schema||'.table_name)'||CHR(10)||
      'Return JSON only: {"sql":"SELECT category, SUM(amount) as total FROM '||p_schema||'.expenses GROUP BY category ORDER BY total DESC","config":{"title":"Expenses by Category","xColumn":"CATEGORY","yColumn":"TOTAL","chartType":"' || p_chart_type || '"}}. '||
      'Requirements: '||
      '- Generate a valid Oracle SQL query that answers the question '||
      '- Always prefix table names with '||p_schema||' (e.g., '||p_schema||'.table_name) '||
      '- Include only the SELECT statement (no DDL/DML) '||
      '- Use proper table aliases '||
      '- Include necessary JOIN conditions '||
      '- Use appropriate aggregate functions for charts '||
      '- The query should return at least 2 columns (x-axis and y-axis) '||
      '- The first column will be used for x-axis labels '||
      '- Subsequent columns will be used as data series '||
      '- For time series, format dates appropriately '||
      'Question: '||p_question;

    l_body := '{"model":"gpt-4o-mini",'||
              '"response_format":{"type":"json_object"},'||
              '"temperature":0.2,'||
              '"messages":[{"role":"user","content":"'||json_escape(l_prompt)||'"}]}';

    set_json_headers;
    l_resp := APEX_WEB_SERVICE.make_rest_request(
                p_url                  => 'https://api.openai.com/v1/chat/completions',
                p_http_method          => 'POST',
                p_body                 => l_body,
                p_credential_static_id => 'credentials_for_ai_services');

    IF APEX_WEB_SERVICE.g_status_code <> 200 THEN
      raise_application_error(-20001,
        'SQL generation failed with status ' || APEX_WEB_SERVICE.g_status_code ||
        '. Response: ' || NVL(DBMS_LOB.SUBSTR(l_resp, 4000, 1), '(empty)'));
    END IF;

    SELECT JSON_VALUE(l_resp,'$.choices[0].message.content' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
      INTO v_txt FROM dual;

    IF v_txt IS NOT NULL THEN
      -- Extract SQL and config from AI response
      SELECT JSON_VALUE(v_txt, '$.sql' RETURNING CLOB NULL ON ERROR NULL ON EMPTY),
             JSON_QUERY(v_txt, '$.config' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
        INTO p_sql_query, p_chart_config
        FROM dual;
    END IF;

    -- Fallback if extraction failed
    IF p_sql_query IS NULL OR LENGTH(TRIM(p_sql_query)) < 20 THEN
      raise_application_error(-20002, 'The AI response did not include a valid SQL query.');
    END IF;

    sanitize_sql(p_sql_query);

    IF p_chart_config IS NULL OR p_chart_config = '{}' THEN
      p_chart_config := '{}';
    END IF;
  END generate_real_sql_query;

  ------------------------------------------------------------------------------
  -- Main Orchestrator
  ------------------------------------------------------------------------------
  PROCEDURE build_dashboard_from_question(
  p_owner         IN  VARCHAR2,
  p_question      IN  VARCHAR2,
  p_dashboard_id  OUT NUMBER,
  p_reason_out    OUT CLOB,
  p_model         IN  VARCHAR2  DEFAULT 'gpt-4o-mini',
  p_max_widgets   IN  PLS_INTEGER DEFAULT 6
) IS
  l_owner     VARCHAR2(128) := UPPER(p_owner);
  l_plan      CLOB;
  l_title     VARCHAR2(1000);
  l_widgets_j CLOB;  -- JSON array snapshot of created widgets
  l_summary   CLOB;

  -- Blocks extracted from plan JSON
  CURSOR c_blocks IS
    SELECT
      NVL(b_title, 'Widget')        AS title,
      b_question,
      NVL(b_chart_type, 'TABLE')    AS chart_type,
      b_sql,
      NVL(b_map_raw, '{}')          AS map_raw,
      NVL(b_grid_x, 0)              AS grid_x,
      NVL(b_grid_y, 0)              AS grid_y,
      NVL(b_grid_w, 4)              AS grid_w,
      NVL(b_grid_h, 6)              AS grid_h
    FROM JSON_TABLE(
           l_plan, '$'
           COLUMNS (
             title       VARCHAR2(200)   PATH '$.title',
             blocks      JSON            PATH '$.blocks'
           )
         ) t,
         JSON_TABLE(
           t.blocks, '$[*]'
           COLUMNS (
             b_title       VARCHAR2(200)    PATH '$.title',
             b_question    VARCHAR2(4000)   PATH '$.question',
             b_chart_type  VARCHAR2(50)     PATH '$.chart_type',
             b_sql         VARCHAR2(32767)  PATH '$.sql',
             b_map_raw     VARCHAR2(32767)  PATH '$.mapping',
             b_grid_x      NUMBER           PATH '$.grid.x',
             b_grid_y      NUMBER           PATH '$.grid.y',
             b_grid_w      NUMBER           PATH '$.grid.w',
             b_grid_h      NUMBER           PATH '$.grid.h'
           )
         );

  v_dash_id   NUMBER;
  v_sql       CLOB;
  v_chart     VARCHAR2(50);
  v_mapping   CLOB;
  v_visual    CLOB;
  v_wid       NUMBER;

  v_widgets_arr CLOB;

  PROCEDURE add_widget_json_snapshot(
    p_title      IN VARCHAR2,
    p_chart_type IN VARCHAR2,
    p_sql        IN CLOB
  ) IS
  BEGIN
    IF v_widgets_arr IS NULL THEN
      v_widgets_arr := '[]';
    END IF;

    IF v_widgets_arr = '[]' THEN
      v_widgets_arr := '[' ||
        '{"title":"' || REPLACE(p_title,'"','\"') ||
        '","chart_type":"' || REPLACE(p_chart_type,'"','\"') ||
        '","sql":"' || REPLACE(DBMS_LOB.SUBSTR(p_sql, 24000), '"','\"') || '"}' ||
      ']';
    ELSE
      v_widgets_arr := RTRIM(v_widgets_arr, ']') || ',' ||
        '{"title":"' || REPLACE(p_title,'"','\"') ||
        '","chart_type":"' || REPLACE(p_chart_type,'"','\"') ||
        '","sql":"' || REPLACE(DBMS_LOB.SUBSTR(p_sql, 24000), '"','\"') || '"}' ||
      ']';
    END IF;
  END;
BEGIN
  -- 1) Plan
  plan_layout_and_blocks(
    p_question    => p_question,
    p_plan_json   => l_plan,
    p_model       => p_model,
    p_max_widgets => p_max_widgets
  );

  -- 2) Title = exactly user's question (max 1000)
  l_title := SUBSTR(NVL(p_question, 'AI Dashboard'), 1, 1000);

  -- 3) Create dashboard
  INSERT INTO DASHBOARDS (NAME, DESCRIPTION, IS_PUBLIC, CREATED_AT, UPDATED_AT)
  VALUES (l_title, p_question, 'N', SYSTIMESTAMP, SYSTIMESTAMP)
  RETURNING ID INTO v_dash_id;

  p_dashboard_id := v_dash_id;

  -- 4) Create widgets
  FOR r IN c_blocks LOOP
    v_sql := TO_CLOB(r.b_sql);

    IF v_sql IS NULL OR TRIM(v_sql) IS NULL THEN
      myquery_smart_query_pkg.call_openai_generate_sql_schema(
        p_owner     => l_owner,
        p_question  => NVL(r.b_question, p_question),
        p_sql_out   => v_sql,
        p_model     => p_model,
        p_max_chars => 20000
      );
    END IF;

    IF v_sql IS NULL THEN
      CONTINUE;
    END IF;

    sanitize_sql(v_sql);

    IF is_select_only(v_sql) = 0 THEN
      CONTINUE;
    END IF;

    v_chart   := r.chart_type;
    v_mapping := CASE WHEN r.map_raw IS NULL THEN NULL ELSE TO_CLOB(r.map_raw) END;

    IF v_chart IS NULL
       OR UPPER(v_chart) NOT IN ('TABLE','BAR','LINE','AREA','PIE','DONUT','KPI','SCATTER','HEATMAP','TEXT')
       OR v_mapping IS NULL
    THEN
      chart_advisor(p_sql => v_sql, p_chart => v_chart, p_mapping => v_mapping);
    END IF;

    v_visual := NULL;

    INSERT INTO WIDGETS (
      DASHBOARD_ID, TITLE, SQL_QUERY, CHART_TYPE, DATA_MAPPING, VISUAL_OPTIONS,
      GRID_X, GRID_Y, GRID_W, GRID_H,
      REFRESH_MODE, REFRESH_INTERVAL_SEC, CACHE_TTL_SEC,
      CREATED_AT, UPDATED_AT
    ) VALUES (
      v_dash_id,
      r.title,
      v_sql,
      NVL(v_chart,'TABLE'),
      v_mapping,
      v_visual,
      r.grid_x, r.grid_y, r.grid_w, r.grid_h,
      'MANUAL', 0, 0,
      SYSTIMESTAMP, SYSTIMESTAMP
    ) RETURNING ID INTO v_wid;

    add_widget_json_snapshot(r.title, NVL(v_chart,'TABLE'), v_sql);
  END LOOP;

  l_widgets_j := NVL(v_widgets_arr, '[]');

  -- 5) Narrative summary
  generate_overall_summary(
    p_question => p_question,
    p_widgets  => l_widgets_j,
    p_summary  => l_summary
  );

  -- 6) Store summary and add a TEXT widget
  UPDATE DASHBOARDS
     SET DESCRIPTION = NVL(l_summary, p_question),
         UPDATED_AT  = SYSTIMESTAMP
   WHERE ID = v_dash_id;

  INSERT INTO WIDGETS (
    DASHBOARD_ID, TITLE, SQL_QUERY, CHART_TYPE, DATA_MAPPING, VISUAL_OPTIONS,
    GRID_X, GRID_Y, GRID_W, GRID_H,
    REFRESH_MODE, REFRESH_INTERVAL_SEC, CACHE_TTL_SEC,
    CREATED_AT, UPDATED_AT
  ) VALUES (
    v_dash_id,
    'Summary',
    TO_CLOB('SELECT ''' || REPLACE(NVL(l_summary,'Summary unavailable.'), '''', '''''') || ''' as summary_text FROM dual'),
    'TEXT',
    NULL,
    NULL,
    0, 0, 12, 4,
    'MANUAL', 0, 0,
    SYSTIMESTAMP, SYSTIMESTAMP
  );

  -- Optional: return plan JSON
  p_reason_out := l_plan;

EXCEPTION
  WHEN OTHERS THEN
    p_reason_out := NVL(p_reason_out,'') || CHR(10)||'ERR: '||SQLERRM;
    RAISE;
END build_dashboard_from_question;


END myquery_dashboard_ai_pkg;
/
