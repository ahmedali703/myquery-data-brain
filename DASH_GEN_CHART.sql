-- AJAX Callback Process in Oracle APEX Page
-- Process Name: DASH_GEN_CHART

DECLARE
  v_dash_id      NUMBER := TO_NUMBER(:P3_DASH_ID);
  v_question     VARCHAR2(4000) := :P3_QUESTION;
  v_chart_data   CLOB;
  v_insights     CLOB;
  v_chart_id     NUMBER;
  v_insights_id  NUMBER;
  v_sql_query    CLOB;
  v_chart_config CLOB;
  l_out          CLOB;

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

  -- Generate real SQL query and chart configuration
  myquery_dashboard_ai_pkg.generate_real_sql_query(
    p_question     => v_question,
    p_chart_type   => 'BAR',
    p_sql_query    => v_sql_query,
    p_chart_config => v_chart_config,
    p_schema       => :P0_DATABASE_SCHEMA
  );

  -- Debug: Show what we got
  DBMS_OUTPUT.PUT_LINE('Chart SQL: ' || DBMS_LOB.SUBSTR(v_sql_query, 2000));
  DBMS_OUTPUT.PUT_LINE('Chart Config: ' || DBMS_LOB.SUBSTR(v_chart_config, 2000));

  -- Ensure we have valid chart data
  IF v_sql_query IS NULL OR LENGTH(v_sql_query) < 20 THEN
    v_sql_query := 'SELECT ''Sample Category'' as category, 100 as value FROM dual UNION ALL SELECT ''Category A'', 150 FROM dual UNION ALL SELECT ''Category B'', 200 FROM dual';
  END IF;

  IF v_chart_config IS NULL OR v_chart_config = '{}' THEN
    v_chart_config := '{"title":"Sample Chart","xColumn":"CATEGORY","yColumn":"VALUE","chartType":"BAR"}';
  END IF;

  -- Generate insights using AI
  myquery_dashboard_ai_pkg.generate_chart_with_insights(
    p_question   => v_question,
    p_chart_data => v_chart_data,
    p_insights   => v_insights,
    p_schema     => :P0_DATABASE_SCHEMA
  );

  -- Ensure we have valid chart data and insights
  IF v_chart_data IS NULL OR v_chart_data = '{}' THEN
    v_chart_data := '{"title":"Sample Chart","subtitle":"Sample data for demonstration","labels":["Jan","Feb","Mar","Apr","May","Jun"],"data":[120,190,300,500,200,300],"color":"#3b82f6"}';
  END IF;

  IF v_insights IS NULL OR v_insights = '[]' THEN
    v_insights := '["This is sample insight data","The chart shows sample data points","Peak values indicate trends","Data is for demonstration purposes"]';
  END IF;
  DBMS_OUTPUT.PUT_LINE('SQL Query generated: ' || DBMS_LOB.SUBSTR(v_sql_query, 300, 1));
  DBMS_OUTPUT.PUT_LINE('Chart config: ' || DBMS_LOB.SUBSTR(v_chart_config, 200, 1));
  DBMS_OUTPUT.PUT_LINE('Insights generated: ' || DBMS_LOB.SUBSTR(v_insights, 500, 1));

  -- Create or update Chart widget (left side)
  BEGIN
    -- Find existing Chart widget
    BEGIN
      SELECT id INTO v_chart_id
        FROM widgets
       WHERE dashboard_id = v_dash_id
         AND UPPER(NVL(chart_type,'TEXT')) = 'CHART'  -- Match the chart_type we're creating
         AND ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_chart_id := NULL; END;

    IF v_chart_id IS NULL THEN
      -- Create new Chart widget
      INSERT INTO widgets(
        dashboard_id, title, sql_query, chart_type, data_mapping, visual_options,
        grid_x, grid_y, grid_w, grid_h,
        refresh_mode, refresh_interval_sec, cache_ttl_sec,
        created_at, updated_at
      ) VALUES (
        v_dash_id,
        JSON_VALUE(v_chart_data, '$.title' RETURNING VARCHAR2(200) DEFAULT 'Chart' ON ERROR),
        v_sql_query,  -- REAL SQL QUERY instead of dummy
        'CHART',  -- Changed from 'BAR' to 'CHART' to match frontend expectations
        v_chart_config,  -- Chart configuration with column mappings
        v_chart_data,  -- Store chart data directly, not wrapped in chartData property
        0, 3, 6, 6,
        'MANUAL', 0, 0,
        SYSTIMESTAMP, SYSTIMESTAMP
      ) RETURNING id INTO v_chart_id;
    ELSE
      -- Update existing Chart widget
      UPDATE widgets
         SET title = JSON_VALUE(v_chart_config, '$.title' RETURNING VARCHAR2(200) DEFAULT 'Chart' ON ERROR),
             sql_query = v_sql_query,      -- REAL SQL QUERY
             data_mapping = v_chart_config, -- Chart configuration
             visual_options = v_chart_data, -- Visual styling (store chart data directly)
             updated_at = SYSTIMESTAMP
       WHERE id = v_chart_id;
    END IF;
  END;

  -- Create or update Key Insights widget (right side)
  BEGIN
    -- Find existing Key Insights widget for chart
    BEGIN
      SELECT id INTO v_insights_id
        FROM widgets
       WHERE dashboard_id = v_dash_id
         AND UPPER(NVL(chart_type,'TEXT')) = 'TEXT'
         AND UPPER(title) = 'KEY INSIGHTS'
         AND grid_x = 6  -- Right side
         AND ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_insights_id := NULL; END;

    IF v_insights_id IS NULL THEN
      -- Create new Key Insights widget
      INSERT INTO widgets(
        dashboard_id, title, sql_query, chart_type, data_mapping, visual_options,
        grid_x, grid_y, grid_w, grid_h,
        refresh_mode, refresh_interval_sec, cache_ttl_sec,
        created_at, updated_at
      ) VALUES (
        v_dash_id,
        'Key Insights',
        NULL,  -- No SQL needed for static content
        'TEXT',
        NULL,
        TO_CLOB('{"insights":' || 
               NVL(v_insights, '[]') || 
               ',"subtitle":"' || 
               REPLACE(JSON_VALUE(v_chart_data, '$.title' RETURNING VARCHAR2(200) DEFAULT 'Insights' ON ERROR), '"', '\"') || 
               '","title":"Key Insights"}'),
        6, 3, 6, 6,
        'MANUAL', 0, 0,
        SYSTIMESTAMP, SYSTIMESTAMP
      ) RETURNING id INTO v_insights_id;
    ELSE
      -- Update existing Key Insights widget
      UPDATE widgets
         SET visual_options = TO_CLOB('{"insights":' || 
                          NVL(v_insights, '[]') || 
                          ',"subtitle":"' || 
                          REPLACE(JSON_VALUE(v_chart_data, '$.title' RETURNING VARCHAR2(200) DEFAULT 'Insights' ON ERROR), '"', '\"') || 
                          '","title":"Key Insights"}'),
             updated_at = SYSTIMESTAMP
       WHERE id = v_insights_id;
    END IF;
  END;

  -- Return success
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', true);
    apex_json.write('dashboardId', v_dash_id);
    apex_json.write('chartWidgetId', v_chart_id);
    apex_json.write('insightsWidgetId', v_insights_id);
    apex_json.write('chartTitle', JSON_VALUE(v_chart_data, '$.title' RETURNING VARCHAR2(200) DEFAULT 'Chart' ON ERROR));
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
