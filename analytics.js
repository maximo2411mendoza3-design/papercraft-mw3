(() => {
  // Set this to the real GA4 ID (format: G-XXXXXXXXXX) to enable analytics.
  const GA4_MEASUREMENT_ID = '';
  const validMeasurementId = /^G-[A-Z0-9]+$/i.test(GA4_MEASUREMENT_ID);

  if (validMeasurementId) {
    window.dataLayer = window.dataLayer || [];
    window.gtag = function() {
      window.dataLayer.push(arguments);
    };
    window.gtag('js', new Date());
    window.gtag('config', GA4_MEASUREMENT_ID);

    const script = document.createElement('script');
    script.async = true;
    script.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(GA4_MEASUREMENT_ID)}`;
    document.head.appendChild(script);
  }

  window.mw3Track = (eventName, parameters = {}) => {
    if (validMeasurementId && typeof window.gtag === 'function') {
      window.gtag('event', eventName, parameters);
    }
  };

  const page = document.body;
  const pageType = page.dataset.mw3PageType;
  if (pageType === 'model') {
    window.mw3Track('view_item', {
      item_name: page.dataset.modelName,
      item_category: page.dataset.modelCategory
    });
  } else if (pageType === 'category') {
    window.mw3Track('view_item_list', {
      item_list_name: page.dataset.categoryName,
      item_list_id: page.dataset.categoryId
    });
  }

  document.addEventListener('click', event => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;

    const explicitEvent = target.closest('[data-mw3-event]');
    if (explicitEvent) {
      const eventName = explicitEvent.dataset.mw3Event;
      window.mw3Track(eventName === 'download_free' ? 'file_download' : eventName, {
        item_name: explicitEvent.dataset.modelName || page.dataset.modelName || undefined
      });
      return;
    }

    const categoryLink = target.closest('a[href^="#category-"]');
    if (categoryLink) {
      const categoryId = categoryLink.getAttribute('href').replace('#category-', '');
      window.mw3Track('view_item_list', { item_list_id: categoryId });
      return;
    }

    const card = target.closest('.card[aria-label^="Ver detalle de "]');
    if (card && !card.closest('.category-preview')) {
      window.mw3Track('view_item', {
        item_name: card.getAttribute('aria-label').replace(/^Ver detalle de /, '')
      });
      return;
    }

    const downloadLink = target.closest('#modal-dl[href], .m2-pill.dl[href]');
    if (downloadLink && !downloadLink.classList.contains('modal-dl-soon')) {
      window.mw3Track('file_download', { link_domain: getHost(downloadLink.href) });
      return;
    }

    const purchaseLink = target.closest('.modal-buy[href], .m2-buy[href], [onclick*="handleMpClick"]');
    if (purchaseLink) {
      window.mw3Track('begin_checkout', { link_domain: purchaseLink.href ? getHost(purchaseLink.href) : undefined });
      return;
    }

    const link = target.closest('a[href^="http"]');
    if (link) {
      window.mw3Track('click_external_link', { link_domain: getHost(link.href) });
    }
  });

  const search = document.getElementById('search');
  if (search) {
    let searchTimer;
    search.addEventListener('input', () => {
      window.clearTimeout(searchTimer);
      if (!search.value.trim()) return;
      searchTimer = window.setTimeout(() => window.mw3Track('search'), 500);
    }, { passive: true });
  }

  function getHost(url) {
    try {
      return new URL(url, window.location.href).hostname;
    } catch (error) {
      return undefined;
    }
  }
})();
