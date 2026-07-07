#===============================================================================
# Another Red Online — special ball shop patch ([019])
#
# Makes four normally-unobtainable Poké Balls purchasable at the Cedolan Dept.
# Store 2F ball counter — the only premium ball shop (Map199 / Map309):
#
#     Safari Ball    200 /     50
#     Dream Ball     300 /    150
#     Beast Ball   1,000 /    250   (KR name: 울트라볼)
#     Master Ball 50,000 / 25,000
#
# Two independent pieces, both baked into the shared build (single-player and
# online alike) and deterministic-neutral (overworld shopping, not battle):
#
#   1) Price patch — Safari Ball has price 0 in items.dat (it would sell for
#      free) and Beast Ball's sell price differs; we set the four balls' buy/
#      sell prices via a GameData::Item.load alias (same pattern as [017]).
#   2) Stock injection — we wrap the global pbPokemonMart and, when the opened
#      stock is the Cedolan ball counter (identified by containing BOTH
#      :QUICKBALL and :TIMERBALL — a combination unique to that shop), append
#      the four balls and re-sort the whole counter by ascending price (stable:
#      equal prices keep their original order).
#
# We do NOT edit base map data; the whole change lives in this script.
#===============================================================================

module ARRedBallShop
  # id => [buy price, sell price]
  PRICES = {
    :SAFARIBALL => [200,     50],
    :DREAMBALL  => [300,    150],
    :BEASTBALL  => [1000,   250],
    :MASTERBALL => [50000, 25000]
  }

  # Balls to add, in display order, to the premium ball counter.
  ADD = [:SAFARIBALL, :DREAMBALL, :BEASTBALL, :MASTERBALL]

  # Item ids whose simultaneous presence identifies the Cedolan Dept. 2F ball
  # counter (the ordinary Poké Marts only ever stock Poké/Great/Ultra Balls).
  MARKERS = [:QUICKBALL, :TIMERBALL]

  # Re-write the four balls' buy/sell prices in the loaded item data. Both
  # values are set explicitly (0 is a valid sell price, so a fallback would not
  # kick in) so the shop shows exactly the intended amounts.
  def self.apply_prices
    return unless defined?(GameData::Item) && GameData::Item.const_defined?(:DATA)
    PRICES.each do |id, (buy, sell)|
      next unless GameData::Item::DATA.has_key?(id)
      item = GameData::Item::DATA[id]
      item.instance_variable_set(:@price, buy)
      item.instance_variable_set(:@sell_price, sell)
    end
  end

  def self.ball_counter?(ids)
    MARKERS.all? { |m| ids.include?(m) }
  end

  # Normalise a stock entry to its item id symbol (entries may be symbols or
  # item objects depending on how the event scripted the mart).
  def self.item_id(x)
    return x if x.is_a?(Symbol)
    (defined?(GameData::Item) && GameData::Item.try_get(x)&.id) || x
  end

  # Buy price of a stock entry (live data, so it reflects our price patch).
  # Unresolvable entries sort to the end rather than jumping to the front.
  def self.price_of(x)
    item = (defined?(GameData::Item) && GameData::Item.try_get(x))
    item ? item.price : Float::INFINITY
  end

  # Sort the stock by ascending buy price. Ruby's sort_by is not stable, so we
  # break ties on the original index — items of the same price keep their
  # existing order (and the appended balls, having higher indices, fall after
  # same-priced originals).
  def self.sort_by_price!(stock)
    indexed = stock.each_with_index.to_a
    indexed.sort_by! { |item, i| [price_of(item), i] }
    stock.replace(indexed.map { |item, _| item })
  end

  # If `stock` is the premium ball counter, append the four extra balls that
  # are not already stocked, then sort the whole counter by price. Returns the
  # (possibly extended/reordered) array.
  def self.augment_stock(stock)
    return stock unless stock.is_a?(Array)
    ids = stock.map { |x| item_id(x) }
    return stock unless ball_counter?(ids)
    ADD.each do |id|
      next if ids.include?(id)
      next unless defined?(GameData::Item) && GameData::Item.exists?(id)
      stock.push(id)
    end
    sort_by_price!(stock)
    stock
  end
end

#-------------------------------------------------------------------------------
# 1) Price patch — re-applied on every data (re)load, like [017].
#-------------------------------------------------------------------------------
if defined?(GameData::Item) && GameData::Item.respond_to?(:load)
  class << GameData::Item
    unless method_defined?(:__arred_orig_load) || private_method_defined?(:__arred_orig_load)
      alias_method :__arred_orig_load, :load
      def load
        __arred_orig_load
        ARRedBallShop.apply_prices
      end
    end
  end
  # If the item data was already loaded before this script ran, patch it now too.
  ARRedBallShop.apply_prices if GameData::Item.const_defined?(:DATA) &&
                                !GameData::Item::DATA.empty?
end

#-------------------------------------------------------------------------------
# 2) Stock injection into the Cedolan ball counter.
#
# pbPokemonMart is a top-level method (a private instance method on Object). We
# alias it and wrap the stock so only the ball counter is affected.
#-------------------------------------------------------------------------------
if Object.private_method_defined?(:pbPokemonMart) || Object.method_defined?(:pbPokemonMart)
  class Object
    unless private_method_defined?(:__arred_orig_pbPokemonMart) ||
           method_defined?(:__arred_orig_pbPokemonMart)
      alias_method :__arred_orig_pbPokemonMart, :pbPokemonMart
      def pbPokemonMart(stock, speech = nil, cantsell = false)
        stock = ARRedBallShop.augment_stock(stock)
        __arred_orig_pbPokemonMart(stock, speech, cantsell)
      end
      private :pbPokemonMart, :__arred_orig_pbPokemonMart
    end
  end
end
