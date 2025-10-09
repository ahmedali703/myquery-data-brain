//Function and Global Variable Declaration

/* =========================================================
 * Page 3 – Streamlined Dashboard (Header + Overview Only)
 * ========================================================= */
(function () {
  const ITEM_Q           = "P3_QUESTION";
  const ITEM_PLAN_JSON   = "P3_PLAN_JSON";
  const ITEM_DASH_ID     = "P3_DASH_ID";
  const REGION_STATIC_ID = "mq_dash";

  const $d = document;
  const sel = (q, el = $d) => el.querySelector(q);

  function normalizeItemToken(token) {
    if (!token) { return null; }
    let t = token.trim();
    if (!t) { return null; }
    if (!t.startsWith("#")) { t = `#${t}`; }
    if (!t.endsWith("#")) { t = `${t}#`; }
    return t;
  }

  function callProcess(name, opts) {
    const options = {};
    const payload = { ...(opts || {}) };

    if (payload.dataType) {
      options.dataType = payload.dataType;
      delete payload.dataType;
    } else {
      options.dataType = "json";
    }

    if (payload.pageItems) {
      const pageItems = Array.isArray(payload.pageItems)
        ? payload.pageItems
        : String(payload.pageItems).split(",");
      const formatted = pageItems
        .map(normalizeItemToken)
        .filter(Boolean)
        .join(",");
      if (formatted) {
        options.pageItems = formatted;
      }
      delete payload.pageItems;
    }

    if (payload.x01 === undefined && window.apex && typeof apex.item === 'function') {
      try {
        const dashItem = apex.item(ITEM_DASH_ID);
        if (dashItem) {
          const dashValue = dashItem.getValue();
          if (dashValue !== null && dashValue !== undefined && String(dashValue).trim() !== '') {
            payload.x01 = dashValue;
          }
        }
      } catch (e) {
        console.debug('Unable to attach dashboard id to request payload', e);
      }
    }

    return apex.server.process(name, payload, options);
  }

  // Progress HUD
  const STEPS = [
    { key: "plan",     label: "Planning" },
    { key: "create",   label: "Creating dashboard" },
    { key: "kpis",     label: "Generating KPIs" },
    { key: "insights", label: "Generating insights" },
    { key: "summary",  label: "Generating description" },
    { key: "overview", label: "Generating overview" },
    { key: "chart",    label: "Creating chart" },
    { key: "final",    label: "Finalizing" }
  ];
  function ensureProgress() {
    let wrap = sel("#mqBuildProgress");
    if (wrap) return wrap;
    wrap = $d.createElement("div");
    wrap.id = "mqBuildProgress";
    wrap.style.cssText = "position:fixed;inset-inline:16px;bottom:16px;z-index:9999;background:#111;color:#e5e5e5;border:1px solid #2d2d2d;border-radius:12px;box-shadow:0 6px 24px rgba(0,0,0,.3);padding:12px 16px;max-width:720px;width:calc(100% - 32px);margin-inline:auto;font:14px/1.4 system-ui,Segoe UI,Roboto,Arial;";
    wrap.innerHTML = `
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:8px">
        <strong style="font-size:14px">AI Dashboard Builder</strong>
        <span id="mqBuildStatus" style="color:#bbb"></span>
        <span id="mqBuildPct" style="margin-inline-start:auto;color:#bbb">0%</span>
      </div>
      <div id="mqBuildSteps" style="display:flex;gap:8px;margin-bottom:10px;flex-wrap:wrap"></div>
      <div style="height:6px;background:#222;border-radius:999px;overflow:hidden">
        <div id="mqBuildBar" style="height:100%;width:0%;background:#2563eb;transition:width .25s ease"></div>
      </div>`;
    const steps = sel("#mqBuildSteps", wrap);
    STEPS.forEach(s => {
      const chip = $d.createElement("div");
      chip.className = "mq-step"; chip.dataset.key = s.key;
      chip.style.cssText = "padding:4px 8px;border-radius:999px;border:1px solid #333;color:#ddd;background:#181818";
      chip.textContent = s.label; steps.appendChild(chip);
    });
    $d.body.appendChild(wrap);
    return wrap;
  }
  function setStepActive(key, sub = "") {
    ensureProgress();
    const status = sel("#mqBuildStatus");
    const chipEls = Array.from($d.querySelectorAll(".mq-step"));
    chipEls.forEach(c => {
      if (c.dataset.key === key) {
        c.style.borderColor = "#2563eb"; c.style.background = "#111a2b"; c.style.color = "#e5e5e5"; c.style.fontWeight = "600";
      } else if (STEPS.findIndex(s => s.key === c.dataset.key) < STEPS.findIndex(s => s.key === key)) {
        c.style.borderColor = "#16a34a"; c.style.background = "#0a2c22"; c.style.color = "#baf7d0";
      }
    });
    if (status) status.textContent = sub ? `— ${sub}` : "";
    const pct = Math.round((STEPS.findIndex(s => s.key === key) / (STEPS.length - 1)) * 100);
    const bar = sel("#mqBuildBar"); const pctEl = sel("#mqBuildPct");
    if (bar) bar.style.width = Math.max(1, pct) + "%";
    if (pctEl) pctEl.textContent = Math.max(1, pct) + "%";
  }
  function finishProgress(ok, msg = "") {
    const bar = sel("#mqBuildBar"); const status = sel("#mqBuildStatus"); const pctEl = sel("#mqBuildPct");
    if (bar) bar.style.width = "100%"; if (pctEl) pctEl.textContent = "100%";
    if (status) status.textContent = msg ? `— ${msg}` : (ok ? "Done" : "Error");
    setTimeout(() => { const wrap = sel("#mqBuildProgress"); if (wrap) wrap.remove(); }, 1800);
  }

  // Render header + overview from GET_DASH_META (Title, Overview, Insights only)
  async function renderHeaderAndOverview() {
    const region = sel('#mqDashboard') || sel('#' + REGION_STATIC_ID) || sel('.t-Region') || $d.body;
    if (!region) return;

    // Get AI-generated content from GET_DASH_META - NO FALLBACKS, NO STATIC VALUES
    let meta = null;
    try {
      const res = await callProcess('GET_DASH_META', { pageItems: [ITEM_DASH_ID] });
      if (res && res.ok) {
        meta = res; // Use ALL data from GET_DASH_META (title, subtitle, insights)
        // Override title with user's question for header/sidebar consistency
        const userQuestion = apex.item(ITEM_Q).getValue();
        if (userQuestion) {
          meta.title = userQuestion;
        }
      }
    } catch (e) { 
      console.error('GET_DASH_META failed:', e); 
      return; // Don't render anything if API fails
    }
    
    if (!meta) {
      console.error('No meta data available');
      return; // Don't render anything if no data
    }

    // Clear any existing widgets/blocks from the region to ensure only our blocks appear
    if (region) {
      const existingCards = region.querySelectorAll('.mq-card:not(#mqTitleBlock):not(#mqOverview):not(#mqChart)');
      existingCards.forEach(card => card.remove());
    }

    // Header bar with title + actions
    let header = sel('#mqHeader');
    if (!header) {
      header = $d.createElement('div');
      header.id = 'mqHeader';
      header.style.cssText = 'display:flex;align-items:center;gap:12px;margin:8px 0 12px;';
      region.parentElement?.insertBefore(header, region);
    }
    header.innerHTML = `
      <h1 style="margin:0;font:600 22px/1.35 system-ui,Segoe UI,Roboto,Arial;">${meta.title}</h1>
      <div style="margin-inline-start:auto;display:flex;gap:8px;">
        <button class="t-Button t-Button--noUI mq-h-act" data-act="new">+ New</button>
        <button class="t-Button t-Button--noUI mq-h-act" data-act="share">Share</button>
        <button class="t-Button t-Button--noUI mq-h-act" data-act="present">Present</button>
        <button class="t-Button t-Button--noUI mq-h-act" data-act="refresh">Refresh</button>
      </div>`;
    header.querySelectorAll('.mq-h-act').forEach(b => b.addEventListener('click', () => {
      const act = b.dataset.act;
      if (act === 'new') {
        try { apex.item(ITEM_DASH_ID).setValue(null); } catch(_) {}
        apex.navigation.redirect(apex.util.makeApplicationUrl({pageId:3, clearCache:'3'}));
      } else if (act === 'share') {
        navigator.clipboard?.writeText(location.href);
        apex.message.showPageSuccess('Link copied');
      } else if (act === 'present') {
        $d.body.classList.toggle('mq-present');
      } else if (act === 'refresh') {
        location.reload();
      }
    }));

    // Title block (large card)
    let titleBlock = sel('#mqTitleBlock');
    if (!titleBlock) {
      titleBlock = $d.createElement('section');
      titleBlock.id = 'mqTitleBlock';
      titleBlock.className = 'mq-card';
      titleBlock.style.cssText = 'margin:6px 0 12px;padding:32px;border:1px solid #f5f4f2;border-radius:12px;background:#fbf9f8;text-align:center;';
      region.parentElement?.insertBefore(titleBlock, region);
    }
    titleBlock.innerHTML = `
      <h2 style="font:600 32px/1.3 system-ui;margin:0 0 8px;">${meta.title}</h2>
      <p style="font:14px/1.5 system-ui;color:#000;margin:0;">${meta.subtitle}</p>`;

    // Overview block
    let ov = sel('#mqOverview');
    if (!ov) {
      ov = $d.createElement('section');
      ov.id = 'mqOverview';
      ov.className = 'mq-card';
      ov.style.cssText = 'margin:6px 0 16px;padding:16px;border:1px solid #f5f4f2;border-radius:12px;background:#fbf9f8;';
      region.parentElement?.insertBefore(ov, region);
    }
    const bullets = (meta.insights || '').split(/\r?\n/).filter(x=>x.trim());
    const insightsHtml = bullets.length ? `<h4 style="margin:16px 0 8px;font:600 16px/1.4 system-ui;">Insights</h4><ul style="margin:0;padding-inline-start:18px;font:14px/1.6 system-ui;">${bullets.map(x=>`<li>${x.replace(/^[-•]\s*/, '')}</li>`).join('')}</ul>` : '';
    
    // Render KPIs with hover effects
    let kpisData = [];
    try {
      if (meta.kpis) {
        const kpisJson = typeof meta.kpis === 'string' ? JSON.parse(meta.kpis) : meta.kpis;
        kpisData = kpisJson?.kpis || [];
      } else if (meta.visual_options && meta.chart_type === 'KPI') {
        const visualOpts = typeof meta.visual_options === 'string' ? JSON.parse(meta.visual_options) : meta.visual_options;
        if (visualOpts && visualOpts.kpis) {
          kpisData = Array.isArray(visualOpts.kpis) ? visualOpts.kpis : [];
        }
      }
    } catch (e) { console.warn('KPI parsing error:', e); }
    
    let kpiHtml = '';
    if (kpisData.length > 0) {
      const kpiCards = kpisData.map(kpi => `
        <div class="mq-kpi" style="
          flex: 1;
          min-width: 200px;
          padding: 20px;
          border: 1px solid #e5e7eb;
          border-radius: 12px;
          background: white;
          text-align: center;
          transition: all 0.3s ease;
          cursor: pointer;
          position: relative;
          overflow: hidden;
        " onmouseover="this.style.transform='translateY(-4px)'; this.style.boxShadow='0 8px 25px rgba(0,0,0,0.15)'; this.style.borderColor='${kpi.color || '#2563eb'}';" 
           onmouseout="this.style.transform='translateY(0)'; this.style.boxShadow='0 2px 8px rgba(0,0,0,0.1)'; this.style.borderColor='#e5e7eb';">
          <div style="font-size: 24px; margin-bottom: 8px;">${kpi.icon || '📊'}</div>
          <div style="font: 600 28px/1.2 system-ui; color: ${kpi.color || '#2563eb'}; margin-bottom: 4px;">
            ${kpi.value}${kpi.unit || ''}
          </div>
          <div style="font: 500 14px/1.4 system-ui; color: #6b7280;">${kpi.title}</div>
          <div style="
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 3px;
            background: ${kpi.color || '#2563eb'};
            opacity: 0;
            transition: opacity 0.3s ease;
          " class="mq-kpi-accent"></div>
        </div>
      `).join('');
      
      kpiHtml = `
        <h4 style="margin:16px 0 12px;font:600 16px/1.4 system-ui;">Key Metrics</h4>
        <div style="display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 16px;">
          ${kpiCards}
        </div>
      `;
    }
    
    ov.innerHTML = `<div style="font:600 16px/1.4 system-ui;">Overview</div><div style="margin-top:6px;font:14px/1.6 system-ui;color:#000;">${meta.overview || ''}</div>${kpiHtml}${insightsHtml}`;
    
    // Add hover effect for accent bar
    if (kpisData.length > 0) {
      ov.querySelectorAll('.mq-kpi').forEach(kpi => {
        const accent = kpi.querySelector('.mq-kpi-accent');
        kpi.addEventListener('mouseenter', () => accent.style.opacity = '1');
        kpi.addEventListener('mouseleave', () => accent.style.opacity = '0');
      });
    }

    // Chart and Key Insights section (side by side)
    await renderChartSection(meta);
  }

  // Render Chart.js chart with Key Insights beside it
  async function renderChartSection(meta) {
    const region = sel('#mqDashboard') || sel('#' + REGION_STATIC_ID) || sel('.t-Region') || $d.body;
    if (!region) return;

    // Load Chart.js if not already loaded
    if (!window.Chart) {
      const script = $d.createElement('script');
      script.src = 'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.5.0/chart.umd.js';
      script.onload = () => renderChartSection(meta); // Retry after loading
      $d.head.appendChild(script);
      return;
    }

    // Get chart data from meta
    let chartData = null;
    let insightsData = [];
    
    try {
      if (meta.chartData) {
        chartData = typeof meta.chartData === 'string' ? JSON.parse(meta.chartData) : meta.chartData;
      }

      if (!chartData && meta.visual_options) {
        const visualOpts = typeof meta.visual_options === 'string' ? JSON.parse(meta.visual_options) : meta.visual_options;
        if (visualOpts) {
          if (visualOpts.chartData) {
            chartData = typeof visualOpts.chartData === 'string' ? JSON.parse(visualOpts.chartData) : visualOpts.chartData;
          } else if (visualOpts.labels && visualOpts.data) {
            chartData = visualOpts;
          }

          if (visualOpts.insights) {
            insightsData = Array.isArray(visualOpts.insights)
              ? visualOpts.insights
              : (typeof visualOpts.insights === 'string' ? JSON.parse(visualOpts.insights) : []);
          }
        }
      }

      if (!insightsData.length && meta.chartInsights) {
        insightsData = Array.isArray(meta.chartInsights)
          ? meta.chartInsights
          : (typeof meta.chartInsights === 'string' ? JSON.parse(meta.chartInsights) : []);
      }

    } catch (e) {
      console.warn('Chart data parsing error:', e);
      console.log('Raw meta:', meta);
      chartData = null;
      insightsData = [];
    }

    // More detailed validation with better error reporting
    const hasValidChart = chartData && 
                         (chartData.title || chartData.subtitle) && 
                         chartData.labels && 
                         Array.isArray(chartData.labels) && 
                         chartData.labels.length > 0 &&
                         chartData.data && 
                         Array.isArray(chartData.data) && 
                         chartData.data.length > 0;
                         
    if (!hasValidChart) {
      console.warn('No valid chart data available for dashboard chart rendering.');
      console.warn('No valid chart data available. ChartData:', chartData);
      // Show placeholder chart section
      let chartContainer = sel('#mqChart');
      if (!chartContainer) {
        chartContainer = $d.createElement('section');
        chartContainer.id = 'mqChart';
        chartContainer.className = 'mq-card';
        chartContainer.style.cssText = 'margin:6px 0 16px;padding:20px;border:1px solid #f5f4f2;border-radius:12px;background:#fbf9f8;text-align:center;';
        region.parentElement?.insertBefore(chartContainer, region);
      }
      chartContainer.innerHTML = `
        <div style="color: #6b7280; font: 14px/1.5 system-ui;">
          <p>Chart data was not returned for this dashboard yet.</p>
          <p style="font-size: 12px;">Run the dashboard generation again once the SQL query produces results.</p>
          <p>Chart data validation failed</p>
          <p style="font-size: 12px;">Debug Info:</p>
          <pre style="font-size: 10px; text-align: left; background: #f0f0f0; padding: 8px; border-radius: 4px; margin: 8px 0;">
chartData exists: ${!!meta.chartData}
chartData type: ${typeof meta.chartData}
chartData content: ${JSON.stringify(meta.chartData, null, 2).substring(0, 200)}...

insights exists: ${!!meta.chartInsights}
insights type: ${typeof meta.chartInsights}
insights content: ${JSON.stringify(meta.chartInsights, null, 2).substring(0, 200)}...

parsed chartData: ${chartData ? JSON.stringify(chartData, null, 2).substring(0, 200) : 'null'}
          </pre>
          <p style="font-size: 12px;">Ensure the dashboard SQL returns numeric data, then run generation again.</p>
        </div>
      `;
      return;
    }

    // Create chart container
    let chartContainer = sel('#mqChart');
    if (!chartContainer) {
      chartContainer = $d.createElement('section');
      chartContainer.id = 'mqChart';
      chartContainer.className = 'mq-card';
      chartContainer.style.cssText = 'margin:6px 0 16px;padding:0;border:1px solid #f5f4f2;border-radius:12px;background:#fbf9f8;display:flex;gap:0;';
      region.parentElement?.insertBefore(chartContainer, region);
    }

    const insightsList = insightsData.length ? insightsData : [];
    const insightsList = insightsData.length ? insightsData : ['No insights available yet.'];

    chartContainer.innerHTML = `
      <div style="flex: 1; padding: 20px; background: white; border-radius: 12px 0 0 12px;">
        <h3 style="margin: 0 0 4px; font: 600 18px/1.4 system-ui;">${chartData.title || 'Chart'}</h3>
        <p style="margin: 0 0 20px; font: 14px/1.4 system-ui; color: #6b7280;">${chartData.subtitle || ''}</p>
        <div style="position: relative; height: 300px;">
          <canvas id="mqChartCanvas"></canvas>
        </div>
      </div>
      <div style="flex: 1; padding: 20px; background: #f8f9fa; border-radius: 0 12px 12px 0;">
        <h3 style="margin: 0 0 4px; font: 600 18px/1.4 system-ui;">Key Insights</h3>
        <p style="margin: 0 0 16px; font: 14px/1.4 system-ui; color: #6b7280;">${chartData.title || ''}</p>
        <ul style="margin: 0; padding: 0; list-style: none;">
          ${insightsList.map(insight => `
            <li style="margin: 0 0 12px; padding: 0; font: 14px/1.5 system-ui; color: #374151; position: relative; padding-left: 8px;">
              <span style="position: absolute; left: -8px; top: 0; color: #6b7280;">•</span>
              ${insight}
            </li>
          `).join('')}
        </ul>
      </div>
    `;

    // Create Chart.js chart
    const canvas = sel('#mqChartCanvas');
    if (canvas && chartData.labels && chartData.data) {
      const rawType = String(chartData.type || chartData.chart_type || '').toLowerCase();
      const chartType = ({
        bar: 'bar',
        column: 'bar',
        line: 'line',
        area: 'line',
        pie: 'pie',
        donut: 'doughnut',
        doughnut: 'doughnut',
        radar: 'radar',
        polararea: 'polarArea',
        scatter: 'scatter',
        bubble: 'bubble'
      })[rawType] || 'bar';
      new Chart(canvas, {
        type: chartType,
        data: {
          labels: chartData.labels,
          datasets: [{
            data: chartData.data,
            backgroundColor: chartData.color || '#3b82f6',
            borderColor: chartData.color || '#3b82f6',
            borderWidth: 0,
            borderRadius: 4,
            borderSkipped: false,
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { display: false },
            tooltip: {
              backgroundColor: 'rgba(0,0,0,0.8)',
              titleColor: 'white',
              bodyColor: 'white',
              cornerRadius: 8,
              displayColors: false
            }
          },
          scales: {
            x: {
              grid: { display: false },
              ticks: { color: '#6b7280', font: { size: 12 } }
            },
            y: {
              grid: { color: '#e5e7eb' },
              ticks: { color: '#6b7280', font: { size: 12 } }
            }
          }
        }
      });
    }
  }

  // Builder: plan -> create -> insights -> summary -> finalize, then render header/overview only
  window.runDashboardBuilder = async function(){
    apex.message.clearErrors();
    ensureProgress();

    // 1) Plan
    try {
      setStepActive('plan', 'Planning layout and blocks…');
      const rawPlan = await callProcess('DASH_PLAN', { pageItems: [ITEM_Q, 'P0_DATABASE_SCHEMA'], dataType: 'text' });
      let planRes = rawPlan;
      if (typeof rawPlan === 'string') { try { planRes = JSON.parse(rawPlan); } catch { throw new Error('Invalid JSON from server (PLAN).'); } }
      if (!planRes || planRes.ok !== true) { throw new Error((planRes && (planRes.error||planRes.title)) || 'Planner failed.'); }
      if (planRes.plan) apex.item(ITEM_PLAN_JSON).setValue(planRes.plan);
    } catch (e) { apex.message.showErrors([{type:'error',location:'page',message:e.message}]); finishProgress(false, 'Failed at Planning'); return; }

    // 2) Create blocks
    let dashId = null;
    try {
      setStepActive('create', 'Creating dashboard and widgets…');
      const createRes = await callProcess('DASH_CREATE_BLOCKS', { pageItems: [ITEM_PLAN_JSON, ITEM_Q] });
      if (!createRes || createRes.ok !== true) throw new Error((createRes && createRes.error) || 'Create failed.');
      dashId = createRes.dashboardId || apex.item(ITEM_DASH_ID).getValue();
      if (!dashId) throw new Error('No dashboardId returned.');
      apex.item(ITEM_DASH_ID).setValue(String(dashId), null, true);
    } catch (e) { apex.message.showErrors([{type:'error',location:'page',message:e.message}]); finishProgress(false, 'Failed at Creating'); return; }

    // 3) KPIs (AI-generated KPI blocks)
    try {
      setStepActive('kpis', 'AI generating KPI metrics…');
     await callProcess('DASH_GEN_KPIS',   { pageItems: [ITEM_DASH_ID, 'P0_DATABASE_SCHEMA'] });
    } catch(e) { console.warn('KPIS warn', e); }

    // 4) Insights (aggregated into single Key Insights widget)
    try {
      setStepActive('insights', 'AI generating insights from data…');
      await callProcess('DASH_GEN_INSIGHTS', { pageItems: [ITEM_DASH_ID, 'P0_DATABASE_SCHEMA'] });
    } catch(e) { console.warn('INSIGHTS warn', e); }

    // 5) Summary (AI-generated small description under title)
    try {
      setStepActive('summary', 'AI generating description…');
      await callProcess('DASH_GEN_SUMMARY', { pageItems: [ITEM_DASH_ID, 'P0_DATABASE_SCHEMA'] });
    } catch(e) { console.warn('SUMMARY warn', e); }

    // 6) Overview (AI-generated overview text for Overview section)
    try {
      setStepActive('overview', 'AI generating overview…');
      await callProcess('DASH_GEN_OVERVIEW', { pageItems: [ITEM_DASH_ID, 'P0_DATABASE_SCHEMA'] });
    } catch(e) { console.warn('OVERVIEW warn', e); }

    // 7) Chart (AI-generated chart with insights)
    try {
      setStepActive('chart', 'AI creating chart with insights…');
      await callProcess('DASH_GEN_CHART', { pageItems: [ITEM_DASH_ID, 'P0_DATABASE_SCHEMA', ITEM_Q] });
    } catch(e) { console.warn('CHART warn', e); }

    // 8) Finalize
    try {
      setStepActive('final', 'Finalizing dashboard…');
      await callProcess('DASH_FINALIZE', { pageItems: [ITEM_DASH_ID, 'P0_DATABASE_SCHEMA'] });
    } catch(e) { console.warn('FINAL warn', e); }

    // Clear placeholder and render all blocks after ALL AI generation is complete
    const placeholder = sel('#mqPlaceholder');
    if (placeholder) placeholder.remove();
    
    setStepActive('final', 'Rendering AI-generated content…');
    await renderHeaderAndOverview();
    finishProgress(true, 'Dashboard ready');
    apex.message.showPageSuccess('Dashboard ready with AI-generated content.');
  };

  // Initial render on page load - only show empty state
  document.addEventListener('DOMContentLoaded', async () => {
    const dashId = apex.item(ITEM_DASH_ID).getValue();
    if (dashId) {
      // Only render if dashboard exists and has been generated
      await renderHeaderAndOverview();
    } else {
      // Show empty state - no blocks until generation
      const region = sel('#mqDashboard') || sel('#' + REGION_STATIC_ID) || sel('.t-Region') || $d.body;
      if (region && region.parentElement) {
        // Clear any existing content
        const existingCards = region.parentElement.querySelectorAll('.mq-card');
        existingCards.forEach(card => card.remove());
        
        // Show placeholder
        const placeholder = $d.createElement('div');
        placeholder.id = 'mqPlaceholder';
        placeholder.style.cssText = 'margin:20px 0;padding:40px;text-align:center;color:#6b7280;font:14px/1.5 system-ui;';
        placeholder.innerHTML = `
          <p style="margin:0 0 8px;font-size:16px;">Ready to create your AI-powered dashboard</p>
          <p style="margin:0;font-size:14px;">Enter your question and click "Generate Dashboard" to begin</p>
        `;
        region.parentElement.insertBefore(placeholder, region);
      }
    }
  });
})();
