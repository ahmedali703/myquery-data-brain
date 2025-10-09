//Execute when Page Loads

(function () {
  if (window.mqSideMenuInit) { return; }
  window.mqSideMenuInit = true;

  // Helpers
  function liHeader(title) {
    return $(`
      <li class="nav-header" role="presentation" aria-hidden="true">
        <div class="thread-category-header">${title}</div>
      </li>
    `);
  }
  function liLink(item, isCurrent) {
    return $(`
      <li id="menu_${item.id}" class="a-TreeView-node a-TreeView-node--leaf">
        <div class="a-TreeView-content ${isCurrent ? "is-current" : ""}">
          ${item.icon ? `<span class="${item.icon}"></span>` : ""}
          <a class="a-TreeView-label" href="${item.target || "#"}" data-id="${item.id}">
            ${item.title}
          </a>
        </div>
      </li>
    `);
  }

  // Optional: log only if APEX Debug is active (Level >= 6)
  function dbg(msg, ...rest) {
    try {
      if (window.apex && apex.debug && typeof apex.debug.getLevel === "function") {
        if (apex.debug.getLevel() >= 6) {
          // Use apex.debug.info if available, fallback to console
          if (apex.debug.info) { apex.debug.info(msg, rest); }
          else { console.log(msg, ...rest); }
        }
      }
    } catch (e) { /* noop */ }
  }

  // FIX: Render dashboards in side navigation and highlight current via server flag
  function refreshSideMenu() {
    apex.server.process("GET_SIDE_MENU", {}, {
      success: function (data) {
        const $menu = $("#t_TreeNav ul");
        $menu.empty();

        // Accept “Chat History” (Page 1) or “Dashboard History” (Page 3)
        const historyHeader = data.find(
          x => x.is_header === "YES" &&
               (x.title === "Chat History" || x.title === "Dashboard History")
        );

        const rootLinks = data.filter(x => x.parent_id == null && x.is_header !== "YES");
        const groupHeaders = data.filter(
          x => historyHeader && x.parent_id === historyHeader.id && x.is_header === "YES"
        );

        // Collect all children under their parent headers
        const childrenByParent = {};
        data.forEach(x => {
          if (x.parent_id != null && x.is_header !== "YES") {
            (childrenByParent[x.parent_id] ||= []).push(x);
          }
        });

        // Root items (e.g., New Dashboard / Query Builder)
        rootLinks.forEach(item => {
          const isCur = (item.is_current === "YES");
          $menu.append(liLink(item, isCur));
        });

        // Divider
        $menu.append('<li class="menu-divider" aria-hidden="true" style="margin:10px 0;border-bottom:1px solid var(--ut-body-nav-border-color, rgba(0,0,0,.1));"></li>');

        // History header and grouped children (Today / Last 30 days)
        if (historyHeader) {
          $menu.append(liHeader(historyHeader.title));
        }
        groupHeaders.forEach(g => {
          $menu.append(liHeader(g.title));
          const children = (childrenByParent[g.id] || []);
          children.forEach(item => {
            const isCur = (item.is_current === "YES");
            $menu.append(liLink(item, isCur));
          });
        });

        dbg(`Side menu refreshed with ${data.length} items.`);
      },
      error: function (err) {
        // Only surface errors when debugging
        dbg("GET_SIDE_MENU error", err);
      }
    });
  }

  // Click behavior (safe to include once)
  $(document).off("click.mqSideNav", "#t_TreeNav .a-TreeView-label");
  $(document).on("click.mqSideNav", "#t_TreeNav .a-TreeView-label", function (e) {
    const $a = $(this);
    const href = $a.attr("href") || "#";

    if (href === "#new") {
      e.preventDefault();
      apex.item("P3_DASH_ID").setValue(null);
      refreshSideMenu();
      return;
    }

    // Client highlight; server will set is_current on next refresh
    $("#t_TreeNav .a-TreeView-content").removeClass("is-current");
    $a.closest(".a-TreeView-content").addClass("is-current");
  });

  // Initialize: refresh once and set a single interval
  refreshSideMenu();

  if (window.mqSideMenuInterval) {
    clearInterval(window.mqSideMenuInterval);
  }
  window.mqSideMenuInterval = setInterval(refreshSideMenu, 10000); // 10s

})();




