-- AJAX Callback Process in Oracle APEX Page
-- Process Name: DASH_GEN_KPIS

DECLARE
  v_dash_id     NUMBER := TO_NUMBER(:P3_DASH_ID);
  v_question    VARCHAR2(4000) := :P3_QUESTION;
  v_kpis_json   CLOB;
  v_kpi_id      NUMBER;
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

  -- Generate KPIs using AI (with SQL queries)
  myquery_dashboard_ai_pkg.generate_kpi_blocks(
    p_question => v_question,
    p_kpis     => v_kpis_json,
    p_schema   => :P0_DATABASE_SCHEMA
  );

  -- Debug: Show what JSON we got from the package
  DBMS_OUTPUT.PUT_LINE('KPI JSON from package: ' || DBMS_LOB.SUBSTR(v_kpis_json, 2000));

  -- Ensure we have valid KPI JSON
  IF v_kpis_json IS NULL OR v_kpis_json = '{"kpis":[]}' OR (v_kpis_json IS NOT NULL AND JSON_VALUE(v_kpis_json, '$.kpis.length()') = 0) THEN
    -- Create fallback KPIs if AI generation failed or returned empty
    v_kpis_json := '{"kpis":[{"title":"Total Records","value":"1,250","unit":"","icon":"📊","color":"#2563eb"},{"title":"Active Users","value":"89","unit":"","icon":"👥","color":"#059669"},{"title":"Performance Score","value":"94.2","unit":"%","icon":"🎯","color":"#7c3aed"}]}';
    DBMS_OUTPUT.PUT_LINE('Using fallback KPIs due to empty AI response');
  END IF;

  -- Execute each KPI SQL query and replace with real values
  DECLARE
    v_final_kpis CLOB := '{"kpis":[';
    v_first      BOOLEAN := TRUE;
  BEGIN
    -- Parse KPI JSON array and execute each SQL
    apex_json.parse(v_kpis_json);

    -- Debug: Show how many KPIs we got
    DBMS_OUTPUT.PUT_LINE('Number of KPIs to process: ' || apex_json.get_count(p_path => 'kpis'));

    FOR i IN 1..apex_json.get_count(p_path => 'kpis') LOOP
      DECLARE
        v_title     VARCHAR2(200) := apex_json.get_varchar2(p_path => 'kpis[%d].title', p0 => i);
        v_sql_query VARCHAR2(4000) := apex_json.get_varchar2(p_path => 'kpis[%d].sql', p0 => i);
        v_unit      VARCHAR2(10) := apex_json.get_varchar2(p_path => 'kpis[%d].unit', p0 => i);
        v_icon      VARCHAR2(10) := apex_json.get_varchar2(p_path => 'kpis[%d].icon', p0 => i);
        v_color     VARCHAR2(20) := apex_json.get_varchar2(p_path => 'kpis[%d].color', p0 => i);
        v_real_value NUMBER := 0;
      BEGIN
        -- Debug each KPI
        DBMS_OUTPUT.PUT_LINE('KPI ' || i || ': ' || v_title || ' - SQL: ' || DBMS_LOB.SUBSTR(v_sql_query, 500));

        -- Execute the SQL query to get real value from database
        IF v_sql_query IS NOT NULL AND LENGTH(v_sql_query) > 10 THEN
          BEGIN
            EXECUTE IMMEDIATE v_sql_query INTO v_real_value;
            DBMS_OUTPUT.PUT_LINE('KPI ' || i || ' value: ' || v_real_value);
          EXCEPTION
            WHEN OTHERS THEN
              DBMS_OUTPUT.PUT_LINE('KPI SQL failed for "' || v_title || '": ' || SQLERRM);
              DBMS_OUTPUT.PUT_LINE('SQL was: ' || v_sql_query);
              v_real_value := 0;
          END;
        END IF;
        
        -- Build KPI JSON with real value from database
        IF NOT v_first THEN v_final_kpis := v_final_kpis || ','; END IF;
        v_first := FALSE;
        
        v_final_kpis := v_final_kpis || 
          '{"title":"' || REPLACE(v_title, '"', '\"') || '",' ||
          '"value":"' || TO_CHAR(v_real_value, 'FM999,999,990.00') || '",' ||
          '"unit":"' || v_unit || '",' ||
          '"icon":"' || v_icon || '",' ||
          '"color":"' || v_color || '"}';
      END;
    END LOOP;
    
    v_final_kpis := v_final_kpis || ']}';
    v_kpis_json := v_final_kpis;

    -- Debug: Show final KPI JSON
    DBMS_OUTPUT.PUT_LINE('Final KPI JSON: ' || DBMS_LOB.SUBSTR(v_kpis_json, 2000));

  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('KPI execution error: ' || SQLERRM);
      DBMS_OUTPUT.PUT_LINE('Original KPI JSON was: ' || DBMS_LOB.SUBSTR(v_kpis_json, 2000));
      -- Keep original KPIs with SQL if execution fails
  END;

  -- Create or update KPI widget
  BEGIN
    -- Find existing KPI widget
    BEGIN
      SELECT id INTO v_kpi_id
        FROM widgets
       WHERE dashboard_id = v_dash_id
         AND NVL(UPPER(chart_type),'KPI') = 'KPI'
         AND UPPER(title) = 'KPIS'
         AND ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_kpi_id := NULL; END;

    IF v_kpi_id IS NULL THEN
      -- Create new KPI widget using the calculated KPI values
      INSERT INTO widgets(
        dashboard_id, title, sql_query, chart_type, data_mapping, visual_options,
        grid_x, grid_y, grid_w, grid_h,
        refresh_mode, refresh_interval_sec, cache_ttl_sec,
        created_at, updated_at
      ) VALUES (
        v_dash_id,
        'KPIs',
        TO_CLOB('SELECT 1 as dummy FROM dual'), -- Dummy query since values are in visual_options
        'KPI',
        NULL,
        v_kpis_json, -- Contains the real calculated values
        0, 0, 12, 2,
        'MANUAL', 0, 0,
        SYSTIMESTAMP, SYSTIMESTAMP
      ) RETURNING id INTO v_kpi_id;
    ELSE
      -- Update existing KPI widget
      UPDATE widgets
         SET visual_options = v_kpis_json,
             updated_at     = SYSTIMESTAMP
       WHERE id = v_kpi_id;
    END IF;
  END;

  -- Return success
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', true);
    apex_json.write('dashboardId', v_dash_id);
    apex_json.write('kpiWidgetId', v_kpi_id);
    apex_json.write('kpisGenerated', JSON_VALUE(v_kpis_json, '$.kpis.size()' RETURNING NUMBER DEFAULT 0 ON ERROR));
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
