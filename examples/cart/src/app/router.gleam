import app/web
import domain.{type Cart, type CartCommand, type CartEvent}
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string_builder
import signal
import wisp.{type Request, type Response}

/// We wrap the request handler with a higher order function to provide a
/// reference to signal
/// 
pub fn handle_request(
  signal: process.Subject(signal.ContextMessage(Cart, CartCommand, CartEvent)),
  revenue_projection: process.Subject(
    signal.ConsumerMessage(domain.Price, domain.CartEvent),
  ),
) {
  fn(req: Request) -> Response {
    use _req <- web.middleware(req)

    case req.method, wisp.path_segments(req) {
      http.Get, ["cart", id] -> cart_overview(id)
      http.Post, ["cart", id] -> add_to_cart(id, req, signal)
      http.Delete, ["cart", id, sku] -> remove_from_cart(id, sku, signal)
      http.Post, ["cart", id, "pay"] ->
        pay_for_cart(id, signal, revenue_projection)
      _, _ -> wisp.not_found()
    }
  }
}

pub fn pay_for_cart(
  id: String,
  signal: process.Subject(signal.ContextMessage(Cart, CartCommand, CartEvent)),
  revenue_projection: process.Subject(
    signal.ConsumerMessage(domain.Price, domain.CartEvent),
  ),
) {
  let result = {
    // Get the cart and handle the command
    use cart <- result.try(signal.aggregate(signal, id))
    signal.handle_command(cart, domain.CompletePurchase)
    // We also want to get the revenue report
  }

  let rev = process.call(revenue_projection, signal.GetConsumerState(_), 50)

  case result {
    Ok(_) ->
      wisp.ok()
      |> wisp.html_body(string_builder.from_string(
        "Revenue: " <> domain.price_to_string(rev),
      ))
    Error(_) -> wisp.bad_request()
  }
}

pub fn remove_from_cart(
  id: String,
  sku: String,
  signal: process.Subject(signal.ContextMessage(Cart, CartCommand, CartEvent)),
) -> Response {
  let result = {
    // Get the cart and handle the command
    use cart <- result.try(signal.aggregate(signal, id))
    signal.handle_command(cart, domain.RemoveFromCart(sku))
  }

  case result {
    Ok(updated) -> display_cart(id, updated)
    Error(_) -> wisp.bad_request()
  }
}

pub fn add_to_cart(
  id: String,
  req: Request,
  signal: process.Subject(signal.ContextMessage(Cart, CartCommand, CartEvent)),
) -> Response {
  use formdata <- wisp.require_form(req)

  let result = {
    use sku <- result.try(
      list.key_find(formdata.values, "sku")
      |> result.replace_error("SKU required"),
    )

    use price <- result.try(
      list.key_find(formdata.values, "price")
      |> result.try(int.parse(_))
      |> result.replace_error("Price required")
      |> result.map(domain.new_price(_))
      |> result.flatten(),
    )

    // We will create a cart if it doesn't exist 
    use cart <- result.try(case signal.aggregate(signal, id) {
      Ok(cart) -> Ok(cart)
      Error(_) -> signal.create(signal, id)
    })

    // Then we handle the command and respond with new state
    signal.handle_command(
      cart,
      domain.AddToCart(domain.Product(wisp.escape_html(sku), 1, price)),
    )
  }

  case result {
    Ok(updated) -> display_cart(id, updated)
    Error(_) -> wisp.bad_request()
  }
}

// Just HTML templates...

fn display_cart(cart_id: String, cart: domain.Cart) {
  let cart_items =
    cart.products
    |> set.to_list()
    |> list.map(fn(product) {
      cart_item(cart_id, product.sku, product.price, product.qty)
    })

  wisp.ok()
  |> wisp.html_body(string_builder.from_strings(cart_items))
}

fn cart_item(
  cart_id: String,
  sku: domain.Sku,
  price: domain.Price,
  qty: domain.Quantity,
) {
  "
      <div class='border p-4'>
        <div class='font-bold'>SKU: " <> sku <> "</div>
        <div>Price: " <> domain.price_to_string(price) <> "</div>
        <div>Quantity: " <> int.to_string(qty) <> "</div>
        <button
          hx-delete='/cart/" <> cart_id <> "/" <> sku <> "'
          hx-swap='innerHTML'
          hx-target='.cart-items'
          class='bg-red-500 hover:bg-red-700 text-white font-bold py-2 px-4 rounded'
        >
          🗑️
        </button>
      </div>
  "
}

fn cart_overview(id: String) -> Response {
  let html = string_builder.from_string("
      <!DOCTYPE html>
      <html lang='en'>
      <head>
        <meta charset='UTF-8'>
        <meta name='viewport' content='width=device-width, initial-scale=1.0'>
        <title>My Website</title>
        <link href='https://cdn.jsdelivr.net/npm/tailwindcss@2.2.19/dist/tailwind.min.css' rel='stylesheet'>
        <script src='https://unpkg.com/htmx.org@2.0.1'></script>
      </head>
      <body class='flex justify-center items-center h-screen'>
        <div id='content' class='grid grid-cols-3 gap-4'>
            <div>
              <form class='mt-4' hx-on--after-request='this.reset()' hx-swap='innerHTML' hx-post='/cart/" <> id <> "'' hx-target='.cart-items'>
                <div class='mb-4'>
                  <label for='sku' class='block font-bold'>SKU:</label>
                  <input type='text' id='sku' name='sku' class='border p-2 w-full' required>
                </div>
                <div class='mb-4'>
                  <label for='price' class='block font-bold'>Price:</label>
                  <input type='number' id='price' name='price' class='border p-2 w-full' required>
                </div>
                <button type='submit' class='bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded'>Add Item</button>
              </form>
            </div>
            <div>
              <div class='cart-items'>
              </div>
              <form class='mt-4'>
                <button type='submit' hx-swap='innerHTML' hx-post='/cart/" <> id <> "/pay'' hx-target='#content' class='bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded'>Order</button>
              </form>
            </div>
            
          <div class='revenue'>

          </div>
        </div>
      </body>
      </html>
      ")
  wisp.ok()
  |> wisp.html_body(html)
}
