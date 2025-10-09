-- AJAX Callback process in Oracle APEX Page
-- Process Name: DASH_FINALIZE
DECLARE
  v_dash_id    NUMBER := TO_NUMBER(:P3_DASH_ID);
  l_out        CLOB;

  v_norm_cnt   NUMBER := 0;  -- chart_type normalized
  v_map_cnt    NUMBER := 0;  -- mappings created/updated
  v_reflow_cnt NUMBER := 0;  -- widgets repositioned

  -- ==== helpers ====
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

  FUNCTION norm_type(p IN VARCHAR2) RETURN VARCHAR2 IS
    t VARCHAR2(50) := UPPER(NVL(p,'TABLE'));
  BEGIN
    IF t = 'DONUT'      THEN RETURN 'DOUGHNUT';
    ELSIF t = 'HEATMAP' THEN RETURN 'BAR';           -- Chart.js core has no heatmap
    ELSIF t = 'AREA'    THEN RETURN 'AREA';          -- rendered as line (filled) في الواجهة
    ELSIF t IN ('DOUGHNUT','PIE','BAR','LINE','SCATTER','TABLE','KPI','TEXT')
      THEN RETURN t;
    ELSE
      RETURN 'TABLE';
    END IF;
  END;

  FUNCTION is_num(code NUMBER) RETURN BOOLEAN IS
  BEGIN
    RETURN code IN (2, 100, 101); -- NUMBER, BINARY_FLOAT, BINARY_DOUBLE
  END;
  FUNCTION is_date(code NUMBER) RETURN BOOLEAN IS
  BEGIN
    RETURN code IN (12, 180, 181, 187, 231); -- DATE/TIMESTAMP variants
  END;

  PROCEDURE infer_mapping_from_sql(
    p_sql     IN  CLOB,
    p_chart   IN  VARCHAR2,
    o_mapping OUT CLOB,
    o_had_map OUT BOOLEAN
  ) IS
    cur      INTEGER;
    colcnt   INTEGER;
    d        DBMS_SQL.DESC_TAB2;
    v_x      VARCHAR2(128) := NULL;
    v_y      VARCHAR2(128) := NULL;
    v_series VARCHAR2(128) := NULL;

    first_str VARCHAR2(128) := NULL;
    second_str VARCHAR2(128) := NULL;
    first_num VARCHAR2(128) := NULL;
    first_dt  VARCHAR2(128) := NULL;
  BEGIN
    o_mapping := NULL; o_had_map := FALSE;

    cur := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(cur, 'SELECT * FROM ('||p_sql||') WHERE ROWNUM <= 1', DBMS_SQL.NATIVE);
    DBMS_SQL.DESCRIBE_COLUMNS2(cur, colcnt, d);
    DBMS_SQL.CLOSE_CURSOR(cur);

    FOR i IN 1..colcnt LOOP
      IF is_num(d(i).col_type) THEN
        IF first_num IS NULL THEN first_num := d(i).col_name; END IF;
      ELSIF is_date(d(i).col_type) THEN
        IF first_dt IS NULL THEN first_dt := d(i).col_name; END IF;
      ELSE
        IF first_str IS NULL THEN first_str := d(i).col_name;
        ELSIF second_str IS NULL THEN second_str := d(i).col_name;
        END IF;
      END IF;
    END LOOP;

    IF p_chart IN ('BAR','LINE','AREA','PIE','DOUGHNUT','SCATTER') THEN
      v_x := NVL(first_dt, first_str);
      v_y := first_num;
      IF v_x IS NULL AND first_str IS NOT NULL THEN v_x := first_str; END IF;
      IF p_chart IN ('BAR','LINE','AREA') AND v_series IS NULL THEN
        IF v_x = first_str AND second_str IS NOT NULL THEN v_series := second_str; END IF;
      END IF;

      apex_json.initialize_clob_output;
      apex_json.open_object;
        IF v_x IS NOT NULL THEN apex_json.write('x', v_x); END IF;
        IF v_y IS NOT NULL THEN apex_json.write('y', v_y); END IF;
        IF v_series IS NOT NULL THEN apex_json.write('series', v_series); END IF;
      apex_json.close_object;
      o_mapping := apex_json.get_clob_output;
      apex_json.free_output;
      o_had_map := (o_mapping IS NOT NULL);
    ELSIF p_chart = 'KPI' THEN
      IF first_num IS NOT NULL THEN
        apex_json.initialize_clob_output;
        apex_json.open_object; apex_json.write('value', first_num); apex_json.close_object;
        o_mapping := apex_json.get_clob_output; apex_json.free_output;
        o_had_map := TRUE;
      END IF;
    ELSE
      o_mapping := NULL; o_had_map := FALSE;
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      IF DBMS_SQL.IS_OPEN(cur) THEN DBMS_SQL.CLOSE_CURSOR(cur); END IF;
      o_mapping := NULL; o_had_map := FALSE;
  END;

  FUNCTION need_xy(p_map CLOB) RETURN BOOLEAN IS
    v_x VARCHAR2(50); v_y VARCHAR2(50);
  BEGIN
    IF p_map IS NULL THEN RETURN TRUE; END IF;
    SELECT JSON_VALUE(p_map,'$.x' RETURNING VARCHAR2(50) NULL ON ERROR NULL ON EMPTY),
           JSON_VALUE(p_map,'$.y' RETURNING VARCHAR2(50) NULL ON ERROR NULL ON EMPTY)
      INTO v_x, v_y FROM dual;
    RETURN (v_x IS NULL OR v_y IS NULL);
  EXCEPTION WHEN OTHERS THEN RETURN TRUE; END;

  FUNCTION need_kpi(p_map CLOB) RETURN BOOLEAN IS
    v_v VARCHAR2(50);
  BEGIN
    IF p_map IS NULL THEN RETURN TRUE; END IF;
    SELECT JSON_VALUE(p_map,'$.value' RETURNING VARCHAR2(50) NULL ON ERROR NULL ON EMPTY)
      INTO v_v FROM dual;
    RETURN (v_v IS NULL);
  EXCEPTION WHEN OTHERS THEN RETURN TRUE; END;

BEGIN
  IF v_dash_id IS NULL THEN
    apex_json.initialize_clob_output;
    apex_json.open_object; apex_json.write('ok', false); apex_json.write('error', 'P3_DASH_ID is NULL'); apex_json.close_object;
    l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out); RETURN;
  END IF;

  -- 1) Normalize chart types + ensure mappings (بدون أي Fallback على DUAL)
  FOR w IN (
    SELECT id, title, chart_type, data_mapping, sql_query, grid_x, grid_y, grid_w, grid_h
      FROM widgets
     WHERE dashboard_id = v_dash_id
     ORDER BY id
  ) LOOP
    DECLARE
      ct_old   VARCHAR2(50) := NVL(w.chart_type,'TABLE');
      ct_new   VARCHAR2(50) := norm_type(ct_old);
      map_new  CLOB := w.data_mapping;
      had_map  BOOLEAN := FALSE;
      changed  BOOLEAN := FALSE;
      v_sql    CLOB := w.sql_query;
    BEGIN
      IF ct_new <> ct_old THEN
        changed := TRUE;
        v_norm_cnt := v_norm_cnt + 1;
      END IF;

      IF ct_new IN ('BAR','LINE','AREA','PIE','DOUGHNUT','SCATTER') THEN
        IF need_xy(map_new) THEN
          infer_mapping_from_sql(v_sql, ct_new, map_new, had_map);
          IF had_map THEN v_map_cnt := v_map_cnt + 1; changed := TRUE; END IF;
        END IF;

      ELSIF ct_new = 'KPI' THEN
        IF need_kpi(map_new) THEN
          infer_mapping_from_sql(v_sql, ct_new, map_new, had_map);
          IF had_map THEN
            v_map_cnt := v_map_cnt + 1; changed := TRUE;
          ELSE
            -- لا يوجد عمود رقمي واضح → حوّله TABLE بدل أي قيمة مزوّرة
            ct_new := 'TABLE';
            changed := TRUE;
          END IF;
        END IF;
      END IF;

      IF changed THEN
        UPDATE widgets
           SET chart_type    = ct_new,
               data_mapping  = map_new,
               updated_at    = SYSTIMESTAMP
         WHERE id = w.id;
      END IF;
    END;
  END LOOP;

  -- 2) Simple vertical reflow to avoid overlaps (stack, keep widths ≤ 12)
  DECLARE
    cur_y NUMBER := 0;
  BEGIN
    FOR w IN (
      SELECT id, grid_x, grid_y, grid_w, grid_h,
             CASE WHEN UPPER(chart_type)='TEXT' THEN 1 ELSE 0 END AS is_text
        FROM widgets
       WHERE dashboard_id = v_dash_id
       ORDER BY is_text, id
    ) LOOP
      UPDATE widgets
         SET grid_x = 0,
             grid_y = cur_y,
             grid_w = LEAST(NVL(grid_w,12), 12),
             updated_at = SYSTIMESTAMP
       WHERE id = w.id;
      cur_y := cur_y + NVL(w.grid_h, 4) + 1;
      v_reflow_cnt := v_reflow_cnt + 1;
    END LOOP;
  END;

  -- 3) Response
  apex_json.initialize_clob_output;
  apex_json.open_object;
    apex_json.write('ok', true);
    apex_json.write('dashboardId', v_dash_id);
    apex_json.write('normalized', v_norm_cnt);
    apex_json.write('mappings', v_map_cnt);
    apex_json.write('reflowed', v_reflow_cnt);
  apex_json.close_object;
  l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);

EXCEPTION
  WHEN OTHERS THEN
    apex_json.initialize_clob_output;
    apex_json.open_object; apex_json.write('ok', false); apex_json.write('error', SQLERRM); apex_json.close_object;
    l_out := apex_json.get_clob_output; apex_json.free_output; out_json(l_out);
END;
