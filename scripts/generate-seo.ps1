param(
  [string]$OutputRoot = '',
  [switch]$CopySiteFiles
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = $root
} elseif (-not [System.IO.Path]::IsPathRooted($OutputRoot)) {
  $OutputRoot = Join-Path $root $OutputRoot
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$baseUrl = 'https://mw3paper.com'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$modelsFile = Join-Path $root 'models.json'

if ($CopySiteFiles -and $OutputRoot -ne [System.IO.Path]::GetFullPath($root)) {
  New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
  $generatedDirectories = @('models', 'helmets', 'figures', 'other', 'services', 'categories')
  foreach ($item in Get-ChildItem -LiteralPath $root -Force) {
    if ($item.Name.StartsWith('.') -or $item.Name -eq 'scripts' -or $generatedDirectories -contains $item.Name) { continue }
    if ($item.FullName -eq $OutputRoot) { continue }
    $destination = Join-Path $OutputRoot $item.Name
    Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
  }
}

if (-not (Test-Path -LiteralPath $modelsFile)) {
  throw "No se encontró models.json en $root"
}

$modelsJson = [System.IO.File]::ReadAllText($modelsFile, [System.Text.Encoding]::UTF8)
$parsedModels = ConvertFrom-Json -InputObject $modelsJson
$modelList = New-Object System.Collections.Generic.List[object]
foreach ($model in $parsedModels) { $modelList.Add($model) }
$models = $modelList.ToArray()
if ($models.Count -eq 0) {
  throw 'models.json no contiene publicaciones.'
}
foreach ($model in $models) {
  foreach ($previewImage in @($model.pepakura.imgs)) {
    if ($previewImage -and -not (Test-Path -LiteralPath (Join-Path $root ([string]$previewImage)))) {
      Write-Warning "Imagen opcional de Pepakura no encontrada para '$($model.name)': $previewImage"
    }
  }
  foreach ($update in @($model.updates)) {
    if ($update.img -and -not (Test-Path -LiteralPath (Join-Path $root ([string]$update.img)))) {
      Write-Warning "Imagen de actualización no encontrada para '$($model.name)': $($update.img)"
    }
  }
}

$categories = @(
  [pscustomobject]@{ Id = 'f1'; Title = 'Fórmula 1'; Route = 'categories/formula-1' },
  [pscustomobject]@{ Id = 'gt3'; Title = 'Autos GT3'; Route = 'categories/gt3' },
  [pscustomobject]@{ Id = 'cascos'; Title = 'Cascos'; Route = 'categories/helmets' },
  [pscustomobject]@{ Id = 'figuras'; Title = 'Figuras'; Route = 'categories/figures' },
  [pscustomobject]@{ Id = 'otros'; Title = 'Otros'; Route = 'categories/other' }
)

function Write-Utf8File {
  param([string]$Path, [string]$Content)
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function ConvertTo-Html {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return '' }
  return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-PlainText {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return '' }
  $text = [regex]::Replace([string]$Value, '(?is)<br\s*/?>', ' ')
  $text = [regex]::Replace($text, '(?is)<[^>]*>', ' ')
  $text = [System.Net.WebUtility]::HtmlDecode($text)
  return ([regex]::Replace($text, '\s+', ' ')).Trim()
}

function ConvertTo-Slug {
  param([string]$Value)
  $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
  $normalized = [regex]::Replace($normalized, '\p{Mn}', '')
  $slug = [regex]::Replace($normalized.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) { return 'modelo-mw3' }
  return $slug
}

function ConvertTo-UrlPath {
  param([string]$Path)
  $segments = $Path.Replace('\', '/').Trim('/').Split('/')
  $escaped = foreach ($segment in $segments) { [uri]::EscapeDataString($segment) }
  return '/' + ($escaped -join '/') + '/'
}

function Get-PageUrl {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return "$baseUrl/" }
  return "$baseUrl$(ConvertTo-UrlPath $Path)"
}

function Get-AssetUrl {
  param([string]$Path)
  $normalized = $Path.Replace('\', '/').TrimStart('/')
  $segments = $normalized.Split('/')
  $escaped = foreach ($segment in $segments) { [uri]::EscapeDataString($segment) }
  return "$baseUrl/" + ($escaped -join '/')
}

function Get-CategoryId {
  param([object]$Model)
  $tags = @($Model.tags | ForEach-Object { [string]$_ })
  if ($Model.isCommission) { return 'otros' }
  if ($Model.isCasco -or ($tags | Where-Object { $_ -ieq 'Casco' })) { return 'cascos' }
  if (($tags | Where-Object { $_ -ieq 'Piloto' }) -or ([string]$Model.name -match '(?i)figura')) { return 'figuras' }
  if (($tags | Where-Object { $_ -match '(?i)trofeo' }) -or ([string]$Model.name -match '(?i)trofeo')) { return 'otros' }
  if (($tags | Where-Object { $_ -match '(?i)gt[\s-]?3' }) -or ([string]$Model.name -match '(?i)gt[\s-]?3')) { return 'gt3' }
  if (($tags | Where-Object { $_ -ieq 'F1' }) -or ([string]$Model.name -match '(?i)\bf1\b')) { return 'f1' }
  return 'otros'
}

function Get-ImageDimensions {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 24 -and $bytes[0] -eq 137 -and $bytes[1] -eq 80 -and $bytes[2] -eq 78 -and $bytes[3] -eq 71) {
    $width = [System.BitConverter]::ToUInt32([byte[]]@($bytes[19], $bytes[18], $bytes[17], $bytes[16]), 0)
    $height = [System.BitConverter]::ToUInt32([byte[]]@($bytes[23], $bytes[22], $bytes[21], $bytes[20]), 0)
    return @{ Width = $width; Height = $height }
  }
  if ($bytes.Length -ge 10 -and $bytes[0] -eq 71 -and $bytes[1] -eq 73 -and $bytes[2] -eq 70) {
    return @{ Width = [int]$bytes[6] + ([int]$bytes[7] -shl 8); Height = [int]$bytes[8] + ([int]$bytes[9] -shl 8) }
  }
  if ($bytes.Length -ge 4 -and $bytes[0] -eq 255 -and $bytes[1] -eq 216) {
    $offset = 2
    while ($offset + 8 -lt $bytes.Length) {
      if ($bytes[$offset] -ne 255) { $offset++; continue }
      $marker = [int]$bytes[$offset + 1]
      $offset += 2
      if ($marker -eq 216 -or $marker -eq 217 -or ($marker -ge 208 -and $marker -le 215)) { continue }
      if ($offset + 1 -ge $bytes.Length) { break }
      $length = ([int]$bytes[$offset] -shl 8) + [int]$bytes[$offset + 1]
      if ($length -lt 2 -or $offset + $length -gt $bytes.Length) { break }
      if (($marker -ge 192 -and $marker -le 195) -or ($marker -ge 197 -and $marker -le 199) -or ($marker -ge 201 -and $marker -le 203) -or ($marker -ge 205 -and $marker -le 207)) {
        $height = ([int]$bytes[$offset + 3] -shl 8) + [int]$bytes[$offset + 4]
        $width = ([int]$bytes[$offset + 5] -shl 8) + [int]$bytes[$offset + 6]
        return @{ Width = $width; Height = $height }
      }
      $offset += $length
    }
  }
  return @{ Width = 0; Height = 0 }
}

function Get-MetaDescription {
  param([string]$Text, [string]$Fallback)
  if ([string]::IsNullOrWhiteSpace($Text)) { $Text = $Fallback }
  $Text = [regex]::Replace($Text, '(?i)La descarga, ya sea gratuita o de pago, no otorga.*$', '').Trim()
  if ($Text.Length -gt 158) {
    $cut = $Text.Substring(0, 155)
    $space = $cut.LastIndexOf(' ')
    if ($space -gt 100) { $cut = $cut.Substring(0, $space) }
    $Text = $cut.TrimEnd(' ', '.', ',', ';', ':') + '…'
  }
  return $Text
}

function ConvertTo-SafeJson {
  param([object]$Value)
  $json = ConvertTo-Json -InputObject $Value -Depth 24 -Compress
  return $json.Replace('</', '<\/')
}

function Build-Head {
  param(
    [string]$Title,
    [string]$Description,
    [string]$Canonical,
    [string]$ImageUrl,
    [string]$ImageAlt,
    [string]$SchemaJson,
    [string]$OgType = 'website'
  )
  $safeTitle = ConvertTo-Html $Title
  $safeDescription = ConvertTo-Html $Description
  $safeImage = ConvertTo-Html $ImageUrl
  $safeImageAlt = ConvertTo-Html $ImageAlt
  return @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="index,follow,max-image-preview:large,max-snippet:-1,max-video-preview:-1">
  <title>$safeTitle</title>
  <meta name="description" content="$safeDescription">
  <link rel="canonical" href="$Canonical">
  <meta property="og:type" content="$OgType">
  <meta property="og:site_name" content="MW3">
  <meta property="og:title" content="$safeTitle">
  <meta property="og:description" content="$safeDescription">
  <meta property="og:url" content="$Canonical">
  <meta property="og:image" content="$safeImage">
  <meta property="og:image:alt" content="$safeImageAlt">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="$safeTitle">
  <meta name="twitter:description" content="$safeDescription">
  <meta name="twitter:image" content="$safeImage">
  <meta name="twitter:image:alt" content="$safeImageAlt">
  <script type="application/ld+json">$SchemaJson</script>
  <script src="/analytics.js" defer></script>
  <style>
    :root{color-scheme:light;--text:#000;--muted:#666;--line:#dedee1;--surface:#fff;--soft:#f4f4f5}
    *{box-sizing:border-box}body{margin:0;background:#fff;color:var(--text);font:16px/1.65 "Segoe UI",system-ui,sans-serif}
    a{color:inherit}header,main,footer{width:min(100% - 32px,960px);margin-inline:auto}
    header{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:20px 0;border-bottom:1px solid var(--line)}
    .brand{font-weight:800;text-decoration:none;letter-spacing:.04em}.site-nav{display:flex;flex-wrap:wrap;gap:16px;font-size:.92rem}
    main{padding:28px 0 56px}.breadcrumbs{font-size:.84rem;color:var(--muted);margin:0 0 18px}.breadcrumbs ol{display:flex;flex-wrap:wrap;gap:8px;list-style:none;padding:0}
    h1{font-size:clamp(1.7rem,4vw,2.4rem);line-height:1.2;margin:.2rem 0 1rem}h2{font-size:1.25rem;margin:2rem 0 .6rem}
    .lead{font-size:1.05rem;color:#333;max-width:75ch}.hero-image{margin:24px 0;background:var(--soft);border:1px solid var(--line);border-radius:16px;overflow:hidden}
    .hero-image img{display:block;width:100%;height:auto}.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px;margin-top:16px}
    .gallery figure,.related-card,.category-card{margin:0;border:1px solid var(--line);border-radius:12px;overflow:hidden;background:var(--surface)}
    .gallery img,.related-card img,.category-card img{display:block;width:100%;height:auto;background:var(--soft)}
    figcaption,.card-copy{padding:10px 12px;color:var(--muted);font-size:.9rem}
    dl{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;margin:12px 0}
    dl div{padding:10px 12px;background:var(--soft);border-radius:9px}dt{font-weight:700}dd{margin:0;color:#444}
    .tags{display:flex;flex-wrap:wrap;gap:8px;padding:0;list-style:none}.tags li{padding:3px 10px;border:1px solid var(--line);border-radius:99px;background:var(--soft);font-size:.86rem}
    .actions{display:flex;flex-wrap:wrap;gap:10px;margin:22px 0}.action{display:inline-flex;padding:10px 16px;border-radius:99px;background:#100c08;color:#fff;text-decoration:none;font-weight:650}
    .action.secondary{background:#f0f0f1;color:#111;border:1px solid var(--line)}.related{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px}
    .related-card{text-decoration:none}.related-card strong{display:block;padding:10px 12px}.category-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}
    .category-card{text-decoration:none}.category-card img{aspect-ratio:4/3;object-fit:cover}.category-card strong{display:block;padding:10px 12px}
    footer{border-top:1px solid var(--line);padding:20px 0 28px;color:var(--muted);font-size:.9rem}
    @media(max-width:560px){header{align-items:flex-start;flex-direction:column}.site-nav{gap:12px}.gallery{grid-template-columns:1fr}}
  </style>
</head>
"@
}

function Build-ModelPage {
  param([object]$Entry, [object[]]$AllEntries)
  $model = $Entry.Model
  $name = [string]$model.name
  $canonical = Get-PageUrl $Entry.Route
  $plainDescription = ConvertTo-PlainText $model.desc
  if ($model.isCommission -and $model.commissionInfo.html) {
    $commissionDescription = ConvertTo-PlainText $model.commissionInfo.html
    if ($commissionDescription) { $plainDescription = $commissionDescription }
  }
  $metaDescription = [string]$Entry.Description
  if ($model.isCommission) {
    $metaDescription = Get-MetaDescription $plainDescription "$name, publicación de papercraft de MW3."
  }
  $imageUrl = Get-AssetUrl $Entry.PrimaryImage
  $imageAlt = "$name — imagen del modelo de papercraft"
  $category = $Entry.Category

  $imagesMarkup = New-Object System.Collections.Generic.List[string]
  $imageUrls = New-Object System.Collections.Generic.List[string]
  $imageNumber = 0
  foreach ($imagePath in @($model.imgs)) {
    if ([string]::IsNullOrWhiteSpace([string]$imagePath)) { continue }
    $localPath = Join-Path $root ([string]$imagePath)
    if (-not (Test-Path -LiteralPath $localPath)) {
      Write-Warning "Se omite una imagen principal inexistente de '$name': $imagePath"
      continue
    }
    $imageNumber++
    $dimensions = Get-ImageDimensions $localPath
    $url = Get-AssetUrl ([string]$imagePath)
    $alt = "$name — vista $imageNumber del modelo de papercraft"
    $loading = if ($imageNumber -eq 1) { 'eager' } else { 'lazy' }
    $priority = if ($imageNumber -eq 1) { ' fetchpriority="high"' } else { '' }
    $size = if ($dimensions.Width -gt 0 -and $dimensions.Height -gt 0) { " width=`"$($dimensions.Width)`" height=`"$($dimensions.Height)`"" } else { '' }
    $figure = "<figure><img src=`"$url`" alt=`"$(ConvertTo-Html $alt)`" loading=`"$loading`" decoding=`"async`"$priority$size><figcaption>$(ConvertTo-Html $alt)</figcaption></figure>"
    if ($imageNumber -eq 1) {
      $imagesMarkup.Add("<figure class=`"hero-image`"><img src=`"$url`" alt=`"$(ConvertTo-Html $alt)`" loading=`"eager`" fetchpriority=`"high`" decoding=`"async`"$size></figure>")
    } else {
      $imagesMarkup.Add($figure)
    }
    $imageUrls.Add($url)
  }
  if ($imageUrls.Count -eq 0) { throw "La publicación '$name' no tiene una imagen principal accesible." }

  $facts = New-Object System.Collections.Generic.List[string]
  $facts.Add("<div><dt>Categoría</dt><dd>$(ConvertTo-Html $category.Title)</dd></div>")
  if ($model.meta) {
    foreach ($property in $model.meta.PSObject.Properties) {
      $value = ConvertTo-PlainText $property.Value
      if ([string]::IsNullOrWhiteSpace($value) -or $value -eq '—') { continue }
      $facts.Add("<div><dt>$(ConvertTo-Html $property.Name)</dt><dd>$(ConvertTo-Html $value)</dd></div>")
    }
  }
  if ($model.scale -and -not ($model.meta -and $model.meta.Escala)) {
    $facts.Add("<div><dt>Escala</dt><dd>$(ConvertTo-Html $model.scale)</dd></div>")
  }
  if ($model.isPremium) {
    $priceText = ''
    if ($null -ne $model.price -and $model.priceCurrency) {
      $priceText = " $($model.priceCurrency) $($model.price)"
    }
    $facts.Add("<div><dt>Tipo</dt><dd>Premium$([string]$priceText)</dd></div>")
  } elseif (-not $model.isCommission) {
    $facts.Add('<div><dt>Tipo</dt><dd>Gratuito</dd></div>')
  }
  $factsMarkup = $facts -join "`n"

  $tagItems = New-Object System.Collections.Generic.List[string]
  foreach ($tag in @($model.tags)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$tag)) { $tagItems.Add("<li>$(ConvertTo-Html $tag)</li>") }
  }
  $tagsMarkup = if ($tagItems.Count) { "<h2>Etiquetas</h2><ul class=`"tags`">$($tagItems -join '')</ul>" } else { '' }

  $actionsMarkup = ''
  $file = [string]$model.file
  if ($model.isCommission -and $model.commissionInfo.link) {
    $actionsMarkup = "<a class=`"action`" href=`"$(ConvertTo-Html $model.commissionInfo.link)`" target=`"_blank`" rel=`"noopener noreferrer`" data-mw3-event=`"begin_checkout`" data-model-name=`"$(ConvertTo-Html $name)`">Ver encargo y opciones</a>"
  } elseif ($file -and $file -ne '#') {
    if ($model.isPremium) {
      $actionsMarkup = "<a class=`"action`" href=`"$(ConvertTo-Html $file)`" target=`"_blank`" rel=`"noopener noreferrer`" data-mw3-event=`"begin_checkout`" data-model-name=`"$(ConvertTo-Html $name)`">Ver opciones de compra</a>"
    } else {
      $actionsMarkup = "<a class=`"action`" href=`"$(ConvertTo-Html $file)`" target=`"_blank`" rel=`"noopener noreferrer`" data-mw3-event=`"download_free`" data-model-name=`"$(ConvertTo-Html $name)`">Ver descarga gratuita</a>"
    }
  } elseif ($file -eq '#') {
    $actionsMarkup = '<span class="action secondary" aria-disabled="true">Próximamente</span>'
  }

  $related = @($AllEntries | Where-Object { $_.Model.name -ne $name -and $_.Category.Id -eq $category.Id } | Select-Object -First 4)
  if ($related.Count -eq 0) {
    $related = @($AllEntries | Where-Object { $_.Model.name -ne $name } | Select-Object -First 4)
  }
  $relatedMarkup = New-Object System.Collections.Generic.List[string]
  foreach ($relatedEntry in $related) {
    $relatedModel = $relatedEntry.Model
    $relatedImage = Get-AssetUrl $relatedEntry.PrimaryImage
    $relatedImagePath = Join-Path $root $relatedEntry.PrimaryImage
    $relatedSize = Get-ImageDimensions $relatedImagePath
    $relatedDimensions = if ($relatedSize.Width -gt 0 -and $relatedSize.Height -gt 0) { " width=`"$($relatedSize.Width)`" height=`"$($relatedSize.Height)`"" } else { '' }
    $relatedAlt = "$($relatedModel.name) — modelo de papercraft"
    $relatedMarkup.Add("<a class=`"related-card`" href=`"$($relatedEntry.Canonical)`"><img src=`"$relatedImage`" alt=`"$(ConvertTo-Html $relatedAlt)`" loading=`"lazy`" decoding=`"async`"$relatedDimensions><strong>$(ConvertTo-Html $relatedModel.name)</strong></a>")
  }
  $relatedSection = if ($relatedMarkup.Count) { "<section aria-labelledby=`"related-title`"><h2 id=`"related-title`">Modelos relacionados</h2><div class=`"related`">$($relatedMarkup -join '')</div></section>" } else { '' }

  $schemaType = if ($model.isCommission) { 'Service' } elseif ($model.isPremium -and $null -ne $model.price -and $model.priceCurrency) { 'Product' } else { 'CreativeWork' }
  $schemaNode = [ordered]@{
    '@type' = $schemaType
    '@id' = "$canonical#item"
    name = $name
    description = $plainDescription
    image = $imageUrls.ToArray()
    url = $canonical
    category = $category.Title
    creator = [ordered]@{ '@type' = 'Organization'; name = 'MW3'; url = "$baseUrl/" }
  }
  if ($schemaType -eq 'Product') {
    $schemaNode.offers = [ordered]@{
      '@type' = 'Offer'
      url = $canonical
      price = ([decimal]$model.price).ToString([Globalization.CultureInfo]::InvariantCulture)
      priceCurrency = [string]$model.priceCurrency
    }
  }
  if ($model.meta.Equipo) { $schemaNode.brand = [ordered]@{ '@type' = 'Brand'; name = [string]$model.meta.Equipo } }
  $breadcrumb = [ordered]@{
    '@type' = 'BreadcrumbList'
    itemListElement = @(
      [ordered]@{ '@type' = 'ListItem'; position = 1; name = 'Inicio'; item = "$baseUrl/" },
      [ordered]@{ '@type' = 'ListItem'; position = 2; name = [string]$category.Title; item = (Get-PageUrl $category.Route) },
      [ordered]@{ '@type' = 'ListItem'; position = 3; name = $name; item = $canonical }
    )
  }
  $schema = [ordered]@{
    '@context' = 'https://schema.org'
    '@graph' = @(
      [ordered]@{ '@type' = 'Organization'; '@id' = "$baseUrl/#organization"; name = 'MW3'; url = "$baseUrl/"; logo = (Get-AssetUrl 'imgs/log23.png') },
      [ordered]@{ '@type' = 'WebSite'; '@id' = "$baseUrl/#website"; url = "$baseUrl/"; name = 'MW3 | Motorsport Papercraft'; publisher = [ordered]@{ '@id' = "$baseUrl/#organization" } },
      [ordered]@{ '@type' = 'WebPage'; '@id' = "$canonical#webpage"; url = $canonical; name = $Entry.SeoTitle; description = $metaDescription; isPartOf = [ordered]@{ '@id' = "$baseUrl/#website" }; primaryImageOfPage = [ordered]@{ '@id' = "$canonical#image" } },
      [ordered]@{ '@type' = 'ImageObject'; '@id' = "$canonical#image"; contentUrl = $imageUrls[0]; caption = $name },
      $schemaNode,
      $breadcrumb
    )
  }
  $schemaJson = ConvertTo-SafeJson $schema
  $head = Build-Head -Title $Entry.SeoTitle -Description $metaDescription -Canonical $canonical -ImageUrl $imageUrl -ImageAlt $imageAlt -SchemaJson $schemaJson -OgType 'article'

  $safeName = ConvertTo-Html $name
  $safeCategory = ConvertTo-Html $category.Title
  $breadcrumbMarkup = "<nav class=`"breadcrumbs`" aria-label=`"Ruta de navegación`"><ol><li><a href=`"/`">Inicio</a></li><li aria-hidden=`"true`">/</li><li><a href=`"$(Get-PageUrl $category.Route)`">$safeCategory</a></li><li aria-hidden=`"true`">/</li><li aria-current=`"page`">$safeName</li></ol></nav>"
  $extraImagesMarkup = if ($imagesMarkup.Count -gt 1) { (@($imagesMarkup.ToArray() | Select-Object -Skip 1) -join '') } else { '' }
  $html = $head + @"
<body data-mw3-page-type="model" data-model-name="$(ConvertTo-Html $name)" data-model-category="$(ConvertTo-Html $category.Id)">
  <header><a class="brand" href="/">MW3</a><nav class="site-nav" aria-label="Navegación principal"><a href="/">Catálogo</a><a href="$(Get-PageUrl $category.Route)">$safeCategory</a><a href="/#faq-title">Preguntas frecuentes</a></nav></header>
  <main>
    $breadcrumbMarkup
    <article>
      <h1>$safeName</h1>
      <p class="lead">$(ConvertTo-Html $plainDescription)</p>
      $($imagesMarkup[0])
      $actionsMarkup
      <section aria-labelledby="details-title"><h2 id="details-title">Información del modelo</h2><dl>$factsMarkup</dl></section>
      $tagsMarkup
      $(if ($extraImagesMarkup) { "<section aria-labelledby=`"gallery-title`"><h2 id=`"gallery-title`">Imágenes del modelo</h2><div class=`"gallery`">$extraImagesMarkup</div></section>" })
    </article>
    $relatedSection
    <p><a href="$(Get-PageUrl $category.Route)">Ver todos los modelos de $safeCategory</a></p>
  </main>
  <footer><a href="/">MW3</a> · Motorsport Papercraft</footer>
</body>
</html>
"@
  return $html
}

function Build-CategoryPage {
  param([object]$Category, [object[]]$Entries)
  $canonical = Get-PageUrl $Category.Route
  $count = $Entries.Count
  $description = "Explorá $count publicaciones de papercraft de $($Category.Title) de MW3. Consultá imágenes e información de cada modelo."
  $title = "$($Category.Title) en papercraft | Catálogo MW3"
  $itemsMarkup = New-Object System.Collections.Generic.List[string]
  $itemList = New-Object System.Collections.Generic.List[object]
  $position = 0
  foreach ($entry in $Entries) {
    $position++
    $model = $entry.Model
    $imagePath = Join-Path $root $entry.PrimaryImage
    $dimensions = Get-ImageDimensions $imagePath
    $size = if ($dimensions.Width -gt 0 -and $dimensions.Height -gt 0) { " width=`"$($dimensions.Width)`" height=`"$($dimensions.Height)`"" } else { '' }
    $imageUrl = Get-AssetUrl $entry.PrimaryImage
    $imageAlt = "$($model.name) — imagen del modelo de papercraft"
    $itemsMarkup.Add("<a class=`"category-card`" href=`"$($entry.Canonical)`"><img src=`"$imageUrl`" alt=`"$(ConvertTo-Html $imageAlt)`" loading=`"lazy`" decoding=`"async`"$size><strong>$(ConvertTo-Html $model.name)</strong></a>")
    $itemList.Add([ordered]@{ '@type' = 'ListItem'; position = $position; url = $entry.Canonical; name = [string]$model.name })
  }
  $logo = Get-AssetUrl 'imgs/log23.png'
  $schema = [ordered]@{
    '@context' = 'https://schema.org'
    '@graph' = @(
      [ordered]@{ '@type' = 'Organization'; '@id' = "$baseUrl/#organization"; name = 'MW3'; url = "$baseUrl/"; logo = $logo },
      [ordered]@{ '@type' = 'WebSite'; '@id' = "$baseUrl/#website"; url = "$baseUrl/"; name = 'MW3 | Motorsport Papercraft'; publisher = [ordered]@{ '@id' = "$baseUrl/#organization" } },
      [ordered]@{ '@type' = 'CollectionPage'; '@id' = "$canonical#webpage"; url = $canonical; name = $title; description = $description; isPartOf = [ordered]@{ '@id' = "$baseUrl/#website" }; mainEntity = [ordered]@{ '@type' = 'ItemList'; numberOfItems = $count; itemListElement = $itemList.ToArray() } },
      [ordered]@{ '@type' = 'BreadcrumbList'; itemListElement = @(
        [ordered]@{ '@type' = 'ListItem'; position = 1; name = 'Inicio'; item = "$baseUrl/" },
        [ordered]@{ '@type' = 'ListItem'; position = 2; name = [string]$Category.Title; item = $canonical }
      ) }
    )
  }
  $schemaJson = ConvertTo-SafeJson $schema
  $head = Build-Head -Title $title -Description $description -Canonical $canonical -ImageUrl $logo -ImageAlt 'Logo de MW3, Motorsport Papercraft' -SchemaJson $schemaJson
  return $head + @"
<body data-mw3-page-type="category" data-category-id="$(ConvertTo-Html $Category.Id)" data-category-name="$(ConvertTo-Html $Category.Title)">
  <header><a class="brand" href="/">MW3</a><nav class="site-nav" aria-label="Navegación principal"><a href="/">Catálogo</a><a href="/#faq-title">Preguntas frecuentes</a></nav></header>
  <main>
    <nav class="breadcrumbs" aria-label="Ruta de navegación"><ol><li><a href="/">Inicio</a></li><li aria-hidden="true">/</li><li aria-current="page">$(ConvertTo-Html $Category.Title)</li></ol></nav>
    <h1>$(ConvertTo-Html $Category.Title) en papercraft</h1>
    <p class="lead">$(ConvertTo-Html $description)</p>
    <section class="category-list" aria-label="Publicaciones de $(ConvertTo-Html $Category.Title)">$($itemsMarkup -join "`n")</section>
  </main>
  <footer><a href="/">MW3</a> · Motorsport Papercraft</footer>
</body>
</html>
"@
}

$entries = New-Object System.Collections.Generic.List[object]
$usedRoutes = @{}
foreach ($model in $models) {
  $categoryId = Get-CategoryId $model
  $category = $categories | Where-Object { $_.Id -eq $categoryId } | Select-Object -First 1
  if (-not $category) { throw "Categoría sin definir para '$($model.name)'." }
  $slug = ConvertTo-Slug ([string]$model.name)
  $routeRoot = if ($model.isCommission) { 'services' } elseif ($categoryId -eq 'cascos') { 'helmets' } elseif ($categoryId -eq 'figuras') { 'figures' } elseif ($categoryId -eq 'otros') { 'other' } else { 'models' }
  $route = "$routeRoot/$slug"
  $counter = 2
  while ($usedRoutes.ContainsKey($route.ToLowerInvariant())) {
    $route = "$routeRoot/$slug-$counter"
    $counter++
  }
  $usedRoutes[$route.ToLowerInvariant()] = $true
  $primaryImage = @($model.imgs | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $root ([string]$_))) } | Select-Object -First 1)[0]
  if ([string]::IsNullOrWhiteSpace([string]$primaryImage)) {
    throw "La publicación '$($model.name)' no tiene una imagen principal válida."
  }
  $plain = ConvertTo-PlainText $model.desc
  $description = Get-MetaDescription $plain "$($model.name), publicación de papercraft de MW3."
  $entry = [pscustomobject]@{
    Model = $model
    Category = $category
    Slug = $slug
    Route = $route
    Canonical = (Get-PageUrl $route)
    PrimaryImage = [string]$primaryImage
    SeoTitle = "$($model.name) | Papercraft MW3"
    Description = $description
  }
  $entries.Add($entry)
}

$generatedFiles = New-Object System.Collections.Generic.List[string]
$duplicateDescriptions = @($entries | Group-Object Description | Where-Object { $_.Count -gt 1 })
foreach ($duplicate in $duplicateDescriptions) {
  foreach ($entry in $duplicate.Group) {
    $entry.Description = Get-MetaDescription "$($entry.Model.name): $($entry.Description)" $entry.Model.name
  }
}
$duplicateTitles = @($entries | Group-Object SeoTitle | Where-Object { $_.Count -gt 1 })
foreach ($duplicate in $duplicateTitles) {
  $suffix = 1
  foreach ($entry in $duplicate.Group) {
    $entry.SeoTitle = "$($entry.SeoTitle) — $suffix"
    $suffix++
  }
}

foreach ($entry in $entries) {
  $pagePath = Join-Path $OutputRoot (Join-Path $entry.Route 'index.html')
  Write-Utf8File -Path $pagePath -Content (Build-ModelPage -Entry $entry -AllEntries $entries.ToArray())
  $generatedFiles.Add((Join-Path $entry.Route 'index.html').Replace('\', '/'))
}

$categoryEntries = New-Object System.Collections.Generic.List[object]
foreach ($category in $categories) {
  $categoryModels = @($entries | Where-Object { $_.Category.Id -eq $category.Id })
  if ($categoryModels.Count -eq 0) { continue }
  $pagePath = Join-Path $OutputRoot (Join-Path $category.Route 'index.html')
  Write-Utf8File -Path $pagePath -Content (Build-CategoryPage -Category $category -Entries $categoryModels)
  $generatedFiles.Add((Join-Path $category.Route 'index.html').Replace('\', '/'))
  $categoryEntries.Add([pscustomobject]@{ Canonical = (Get-PageUrl $category.Route); Title = $category.Title })
}

$homeUrl = Get-PageUrl ''
$allPageUrls = New-Object System.Collections.Generic.List[string]
$allPageUrls.Add($homeUrl)
foreach ($categoryEntry in $categoryEntries) { $allPageUrls.Add($categoryEntry.Canonical) }

$sitemapLines = New-Object System.Collections.Generic.List[string]
$imageSitemapLines = New-Object System.Collections.Generic.List[string]
$sitemapLines.Add('<?xml version="1.0" encoding="UTF-8"?>')
$sitemapLines.Add('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">')
$imageSitemapLines.Add('<?xml version="1.0" encoding="UTF-8"?>')
$imageSitemapLines.Add('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">')
foreach ($url in $allPageUrls) {
  $sitemapLines.Add("  <url><loc>$([System.Security.SecurityElement]::Escape($url))</loc></url>")
}
$seenImageUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $entries) {
  $imageUrl = Get-AssetUrl $entry.PrimaryImage
  $loc = [System.Security.SecurityElement]::Escape($entry.Canonical)
  $img = [System.Security.SecurityElement]::Escape($imageUrl)
  $caption = [System.Security.SecurityElement]::Escape([string]$entry.Model.name)
  $sitemapLines.Add("  <url><loc>$loc</loc><image:image><image:loc>$img</image:loc><image:title>$caption</image:title></image:image></url>")
  if ($seenImageUrls.Add($imageUrl)) {
    $imageSitemapLines.Add("  <url><loc>$loc</loc><image:image><image:loc>$img</image:loc><image:title>$caption</image:title></image:image></url>")
  }
}
$sitemapLines.Add('</urlset>')
$imageSitemapLines.Add('</urlset>')
Write-Utf8File -Path (Join-Path $OutputRoot 'sitemap.xml') -Content ($sitemapLines -join "`n")
Write-Utf8File -Path (Join-Path $OutputRoot 'sitemap-images.xml') -Content ($imageSitemapLines -join "`n")
Write-Utf8File -Path (Join-Path $OutputRoot 'robots.txt') -Content "User-agent: *`nAllow: /`n`nSitemap: $baseUrl/sitemap.xml`nSitemap: $baseUrl/sitemap-images.xml`n"

$manifestPath = Join-Path $OutputRoot '.mw3-generated-seo.json'
$previousFiles = @()
if (Test-Path -LiteralPath $manifestPath) {
  $previous = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8))
  $previousFiles = @($previous.files)
}
$currentFiles = @($generatedFiles | Sort-Object -Unique)
foreach ($oldFile in $previousFiles) {
  if ($currentFiles -contains [string]$oldFile) { continue }
  $oldPath = Join-Path $OutputRoot ([string]$oldFile)
  if ((Test-Path -LiteralPath $oldPath) -and $oldPath.StartsWith($OutputRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $oldPath -Force
    $oldDirectory = Split-Path -Parent $oldPath
    if ((Test-Path -LiteralPath $oldDirectory) -and -not (Get-ChildItem -LiteralPath $oldDirectory -Force | Select-Object -First 1)) {
      Remove-Item -LiteralPath $oldDirectory -Force
    }
  }
}
$manifestJson = ConvertTo-Json -InputObject ([ordered]@{ files = $currentFiles }) -Depth 5
Write-Utf8File -Path $manifestPath -Content $manifestJson

$imageDimensions = [ordered]@{}
$imageFiles = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
  $_.Extension -match '^\.(png|jpe?g|gif)$' -and $_.FullName -notmatch '[\\/]\.(git|vscode|github)[\\/]'
}
foreach ($imageFile in $imageFiles) {
  $relativePath = $imageFile.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
  $dimensions = Get-ImageDimensions $imageFile.FullName
  if ($dimensions.Width -gt 0 -and $dimensions.Height -gt 0) {
    $imageDimensions[$relativePath] = [ordered]@{ width = $dimensions.Width; height = $dimensions.Height }
  }
}
$dimensionScript = 'window.MW3_IMAGE_DIMENSIONS = ' + (ConvertTo-SafeJson $imageDimensions) + ';'
Write-Utf8File -Path (Join-Path $OutputRoot 'image-dimensions.js') -Content $dimensionScript

Write-Output "SEO generado: $($entries.Count) páginas de publicaciones, $($categoryEntries.Count) categorías."
Write-Output "Sitemap: $(Join-Path $OutputRoot 'sitemap.xml')"
Write-Output "Sitemap de imágenes: $(Join-Path $OutputRoot 'sitemap-images.xml')"
