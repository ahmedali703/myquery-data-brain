-- AJAX Callback Process in Oracle APEX Page
-- Process Name: GET_DASH_META
DECLARE
  v_dash_id        NUMBER := TO_NUMBER(NVL(NULLIF(:P3_DASH_ID, ''), NULLIF(apex_application.g_x01, '')));
  v_title          VARCHAR2(1000);
  v_subtitle       CLOB;  -- Small description under title
  v_overview       CLOB;  -- Overview section text
  v_insights       CLOB;  -- Insights bullets
  v_kpis           CLOB;  -- KPI blocks JSON
  v_chart_data     CLOB;  -- Chart data
  v_chart_insights CLOB;  -- Chart insights
  v_out            CLOB;
BEGIN
  IF v_dash_id IS NULL THEN
    apex_json.initialize_clob_output;
    apex_json.open_object;
    apex_json.write('ok', false);
    apex_json.write('error', 'P3_DASH_ID is NULL');
    apex_json.close_object;
    v_out := apex_json.get_clob_output; apex_json.free_output;
    owa_util.mime_header('application/json', FALSE);
    owa_util.http_header_close;
    htp.prn(v_out);
    RETURN;
  END IF;

  -- Dashboard title and subtitle/description
  SELECT NAME, DESCRIPTION
    INTO v_title, v_subtitle
    FROM DASHBOARDS
   WHERE ID = v_dash_id;

  -- Prefer a dedicated 'Key Insights' text if exists; fallback to concatenation of per-widget insights; fallback to summary
  BEGIN
    SELECT JSON_VALUE(VISUAL_OPTIONS, '$.text' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
      INTO v_insights
      FROM WIDGETS
     WHERE DASHBOARD_ID = v_dash_id
       AND UPPER(NVL(CHART_TYPE,'TEXT')) = 'TEXT'
       AND UPPER(TITLE) LIKE 'KEY INSIGHTS%'
       AND ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN v_insights := NULL; END;

  -- Strip placeholders from insights if any
  IF v_insights IS NOT NULL THEN
    IF REGEXP_LIKE(v_insights, '^\s*(Insights will appear after generation\.|No insights\.)\s*$', 'i') THEN
      v_insights := NULL;
    END IF;
  END IF;

  IF v_insights IS NULL THEN
    SELECT LISTAGG(txt, CHR(10)) WITHIN GROUP (ORDER BY id)
      INTO v_insights
      FROM (
        SELECT id,
               CASE
                 WHEN REGEXP_LIKE(JSON_VALUE(VISUAL_OPTIONS,'$.text' RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY), '^\s*(Insights will appear after generation\.|No insights\.)\s*$', 'i') THEN NULL
                 ELSE '- '||JSON_VALUE(VISUAL_OPTIONS,'$.text' RETURNING VARCHAR2(4000) NULL ON ERROR NULL ON EMPTY)
               END AS txt
          FROM WIDGETS
         WHERE DASHBOARD_ID = v_dash_id
           AND UPPER(NVL(CHART_TYPE,'TEXT')) = 'TEXT'
           AND TITLE LIKE '% — Insights'
      ) t
     WHERE txt IS NOT NULL;
  END IF;

  -- Get Overview widget text
  BEGIN
    SELECT JSON_VALUE(VISUAL_OPTIONS, '$.text' RETURNING CLOB NULL ON ERROR NULL ON EMPTY)
      INTO v_overview
      FROM WIDGETS
     WHERE DASHBOARD_ID = v_dash_id
       AND UPPER(NVL(CHART_TYPE,'TEXT')) = 'TEXT'
       AND UPPER(TITLE) = 'OVERVIEW'
       AND ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN v_overview := NULL; END;

  -- Clean up placeholder values
  IF v_subtitle IS NOT NULL AND REGEXP_LIKE(v_subtitle, '^\s*Summary unavailable\.?\s*$', 'i') THEN
    v_subtitle := NULL;
  END IF;
  
  IF v_overview IS NOT NULL AND REGEXP_LIKE(v_overview, '^\s*(No overview\.|Overview unavailable\.)\s*$', 'i') THEN
    v_overview := NULL;
  END IF;

  -- Get KPIs widget JSON
  BEGIN
    SELECT VISUAL_OPTIONS
      INTO v_kpis
      FROM WIDGETS
     WHERE DASHBOARD_ID = v_dash_id
       AND UPPER(NVL(CHART_TYPE,'TEXT')) = 'TEXT'
       AND UPPER(TITLE) = 'KPIS'
       AND ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN v_kpis := NULL; END;

  -- Get Chart data and Chart Insights
  BEGIN
    -- Get chart widget data
    SELECT VISUAL_OPTIONS
      INTO v_chart_data
      FROM WIDGETS
     WHERE DASHBOARD_ID = v_dash_id
       AND UPPER(NVL(CHART_TYPE,'TEXT')) IN ('BAR','CHART')
       AND ROWNUM = 1;
       
    -- Get chart insights widget data
    SELECT JSON_QUERY(VISUAL_OPTIONS, '$.insights' RETURNING CLOB)
      INTO v_chart_insights
      FROM WIDGETS
     WHERE DASHBOARD_ID = v_dash_id
       AND UPPER(NVL(CHART_TYPE,'TEXT')) = 'TEXT'
       AND UPPER(TITLE) = 'KEY INSIGHTS'
       AND grid_x = 6  -- Right side
       AND ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN 
    v_chart_data := NULL;
    v_chart_insights := NULL;
  END;

  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', true);
    apex_json.write('title', NVL(v_title,'Dashboard'));
    apex_json.write('subtitle', NVL(v_subtitle, ''));
    apex_json.write('overview', NVL(v_overview, ''));
    apex_json.write('insights', NVL(v_insights, ''));
    IF v_kpis IS NOT NULL THEN
      apex_json.write('kpis', v_kpis);
    ELSE
      apex_json.write_null('kpis');
    END IF;
    IF v_chart_data IS NOT NULL THEN
      apex_json.write('chartData', v_chart_data);
    ELSE
      apex_json.write_null('chartData');
    END IF;
    IF v_chart_insights IS NOT NULL THEN
      apex_json.write('chartInsights', v_chart_insights);
    ELSE
      apex_json.write_null('chartInsights');
    END IF;
  apex_json.close_object;
  v_out := apex_json.get_clob_output; apex_json.free_output;
  owa_util.mime_header('application/json', FALSE);
  owa_util.http_header_close;
  htp.prn(v_out);
EXCEPTION
  WHEN OTHERS THEN
    apex_json.initialize_clob_output;
    apex_json.open_object; apex_json.write('ok', false); apex_json.write('error', SQLERRM); apex_json.close_object;
    v_out := apex_json.get_clob_output; apex_json.free_output;
    owa_util.mime_header('application/json', FALSE);
    owa_util.http_header_close;
    htp.prn(v_out);
END;

