-- AJAX Callback Process in Oracle APEX Page
-- Process Name: DASH_GEN_CHART

DECLARE
  v_dash_id      NUMBER := TO_NUMBER(NVL(NULLIF(:P3_DASH_ID, ''), NULLIF(APEX_APPLICATION.G_X01, '')));
  v_question     VARCHAR2(4000) := :P3_QUESTION;
  v_chart_data   CLOB;
  v_insights     CLOB;
  v_chart_id     NUMBER;
  v_insights_id  NUMBER;
  v_sql_query    CLOB;
  v_chart_config CLOB;
  l_out          CLOB;
  TYPE t_label_tab IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
  TYPE t_value_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  v_labels        t_label_tab;
  v_values        t_value_tab;
  v_point_count   PLS_INTEGER := 0;
  v_cursor        INTEGER;
  v_desc          DBMS_SQL.desc_tab2;
  v_col_count     PLS_INTEGER;
  v_label_value   VARCHAR2(4000);
  v_value_text    VARCHAR2(4000);
  v_value_number  NUMBER;
  v_sql_x_col     VARCHAR2(4000);
  v_sql_y_col     VARCHAR2(4000);
  v_cfg_title     VARCHAR2(4000);
  v_cfg_subtitle  VARCHAR2(4000);
  v_cfg_color     VARCHAR2(64);
  v_cfg_chart     VARCHAR2(100);
  v_cfg_x_col     VARCHAR2(4000);
  v_cfg_y_col     VARCHAR2(4000);
  v_final_title   VARCHAR2(4000);
  v_final_sub     VARCHAR2(4000);
  v_final_color   VARCHAR2(64);
  v_final_chart   VARCHAR2(100);
  v_final_x_col   VARCHAR2(4000);
  v_final_y_col   VARCHAR2(4000);
  l_insights_ok   NUMBER := 0;
  c_max_points    CONSTANT PLS_INTEGER := 50;

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

  -- Execute the generated SQL and build chart data from the actual result set
  v_cursor := DBMS_SQL.open_cursor;
  BEGIN
    DBMS_SQL.parse(v_cursor, v_sql_query, DBMS_SQL.native);
    DBMS_SQL.describe_columns2(v_cursor, v_col_count, v_desc);

    IF v_col_count < 2 THEN
      RAISE_APPLICATION_ERROR(-20003, 'Generated SQL must return at least two columns.');
    END IF;

    v_sql_x_col := NVL(v_desc(1).col_name, 'LABEL');
    v_sql_y_col := NVL(v_desc(2).col_name, 'VALUE');

    DBMS_SQL.define_column(v_cursor, 1, v_label_value, 4000);
    DBMS_SQL.define_column(v_cursor, 2, v_value_text, 4000);

    DBMS_SQL.execute(v_cursor);

    LOOP
      EXIT WHEN DBMS_SQL.fetch_rows(v_cursor) = 0 OR v_point_count >= c_max_points;

      DBMS_SQL.column_value(v_cursor, 1, v_label_value);
      DBMS_SQL.column_value(v_cursor, 2, v_value_text);

      v_value_number := NULL;
      IF v_value_text IS NOT NULL THEN
        BEGIN
          v_value_number := TO_NUMBER(REPLACE(TRIM(v_value_text), ',', ''));
        EXCEPTION
          WHEN VALUE_ERROR THEN
            v_value_number := NULL;
        END;
      END IF;

      IF v_label_value IS NOT NULL AND v_value_number IS NOT NULL THEN
        v_point_count := v_point_count + 1;
        v_labels(v_point_count) := v_label_value;
        v_values(v_point_count) := v_value_number;
      END IF;
    END LOOP;

    DBMS_SQL.close_cursor(v_cursor);
  EXCEPTION
    WHEN OTHERS THEN
      IF DBMS_SQL.is_open(v_cursor) THEN
        DBMS_SQL.close_cursor(v_cursor);
      END IF;
      RAISE;
  END;

  IF v_point_count = 0 THEN
    RAISE_APPLICATION_ERROR(-20004, 'Generated SQL returned no numeric rows to chart.');
  END IF;

  -- Read any optional presentation settings from the AI config
  SELECT JSON_VALUE(v_chart_config, '$.title'     RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY),
         JSON_VALUE(v_chart_config, '$.subtitle' RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY),
         JSON_VALUE(v_chart_config, '$.color'    RETURNING VARCHAR2(64)   NULL ON ERROR NULL ON EMPTY),
         JSON_VALUE(v_chart_config, '$.chartType' RETURNING VARCHAR2(100) NULL ON ERROR NULL ON EMPTY),
         JSON_VALUE(v_chart_config, '$.xColumn'  RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY),
         JSON_VALUE(v_chart_config, '$.yColumn'  RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY)
    INTO v_cfg_title, v_cfg_subtitle, v_cfg_color, v_cfg_chart, v_cfg_x_col, v_cfg_y_col
    FROM dual;

  v_final_title := NVL(v_cfg_title, SUBSTR(REPLACE(NVL(v_question, 'AI Chart'), '"', ''), 1, 200));
  v_final_sub   := NVL(v_cfg_subtitle, '');
  v_final_color := NVL(v_cfg_color, '#2563eb');
  v_final_chart := NVL(v_cfg_chart, 'BAR');
  v_final_x_col := NVL(v_cfg_x_col, v_sql_x_col);
  v_final_y_col := NVL(v_cfg_y_col, v_sql_y_col);

  -- Build chart data JSON
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('title', v_final_title);
    apex_json.write('subtitle', v_final_sub);
    apex_json.open_array('labels');
      FOR i IN 1..v_point_count LOOP
        apex_json.write(v_labels(i));
      END LOOP;
    apex_json.close_array;
    apex_json.open_array('data');
      FOR i IN 1..v_point_count LOOP
        apex_json.write(v_values(i));
      END LOOP;
    apex_json.close_array;
    apex_json.write('color', v_final_color);
  apex_json.close_object;
  v_chart_data := apex_json.get_clob_output; apex_json.free_output;

  -- Build chart configuration JSON
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('title', v_final_title);
    apex_json.write('xColumn', v_final_x_col);
    apex_json.write('yColumn', v_final_y_col);
    apex_json.write('chartType', v_final_chart);
    apex_json.write('color', v_final_color);
  apex_json.close_object;
  v_chart_config := apex_json.get_clob_output; apex_json.free_output;

  -- Generate insights using AI based on the real data
  myquery_dashboard_ai_pkg.generate_chart_with_insights(
    p_question   => v_question,
    p_sql_query  => v_sql_query,
    p_chart_data => v_chart_data,
    p_insights   => v_insights,
    p_schema     => :P0_DATABASE_SCHEMA
  );

  -- Validate insights JSON (allow empty array)
  IF v_insights IS NULL THEN
    v_insights := '[]';
  ELSE
    BEGIN
      SELECT CASE WHEN JSON_EXISTS(v_insights, '$[*]') THEN 1 ELSE 0 END
        INTO l_insights_ok
        FROM dual;
    EXCEPTION
      WHEN OTHERS THEN
        l_insights_ok := 0;
    END;

    IF l_insights_ok = 0 THEN
      v_insights := '[]';
    END IF;
  END IF;
  DBMS_OUTPUT.PUT_LINE('SQL Query generated: ' || DBMS_LOB.SUBSTR(v_sql_query, 300, 1));
  DBMS_OUTPUT.PUT_LINE('Chart rows fetched: ' || v_point_count);
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
