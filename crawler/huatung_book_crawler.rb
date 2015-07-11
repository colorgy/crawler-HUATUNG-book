require 'iconv'
require 'crawler_rocks'
require 'json'
require 'isbn'
require 'pry'

require 'thread'
require 'thwait'

class HuatungBookCrawler
  include CrawlerRocks::DSL

  ATTR_KEY = {
    "出版商" => :publisher,
    "出版日期" => :date,
    "條碼" => :barcode,
    "BOOKID" => :internal_code,
    "ISBN" => :isbn,
    "作者" => :author,
  }

  def initialize
    @index_url = "http://www.huatung.com/index.php"
  end

  def books
    @books = []
    @paginate_threads = []

    start_no = 0
    loop do
      sleep(1) until (
        @paginate_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @paginate_threads.count < (ENV['MAX_THREADS'] || 10)
      )
      @paginate_threads << Thread.new do
        r = RestClient.get @index_url + "?" + {
          "PHP_action" =>  'browse_book',
          "PHP_sr_parm_is_not_oldversion" => 1,
          "PHP_listmode" => 2,
          "PHP_sr_parm_is_in_stock" => 1,
          "PHP_sr_startno" => start_no
        }.map{|k, v| "#{k}=#{v}"}.join('&')
        doc = Nokogiri::HTML(r)

        start_no += 10

        @threads = []
        rows = doc.xpath('//table[@width="639"]//tr[@bgcolor]')
        if rows.count == 0
          print "now it should be end"
          @ending_flag = true
          break
        end

        rows.each do |row|
          sleep(1) until (
            @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
            @threads.count < (ENV['MAX_THREADS'] || 30)
          )
          @threads << Thread.new do
            book = {}
            datas = row.xpath('td')

            basic_data = datas[0]

            url = basic_data && URI.join(@index_url, basic_data.xpath('a[position()=1]//@href').to_s).to_s
            external_image_url = basic_data && URI.join(@index_url, basic_data.xpath('a/img/@src').to_s).to_s
            name = basic_data.xpath('a')[0].children[2].text
            author = datas[1] && datas[1].text
            price = datas[2] && datas[2].text.gsub(/[^\d]/, '').to_i

            book[:url] = url
            book[:external_image_url] = external_image_url
            book[:name] = name
            book[:author] = author
            book[:price] = price

            # attr_datas = basic_data.xpath('a/jw').text.split("\n").map(&:strip).select{|s| !s.empty?}
            r = RestClient.get url
            doc = Nokogiri::HTML(r)

            attr_datas = doc.xpath('//table[@width="428"]/tr[2]/td/table/tr/td[2]/table/tr[position()>1]').map{|tr| tr.text.strip }.select{|tr| !tr.empty? && tr != " "}
            attr_datas.each {|data|
              key = ATTR_KEY[data.rpartition(/[:：]/)[0]]
              key && book[key] = data.rpartition(/[:：]/)[-1]
            }

            book[:isbn] = book[:isbn] && isbn_to_13(book[:isbn])

            @books << book
          end # end Thread do
        end # end each row

        print "page: #{start_no / 10}\n"
      end # end paginate_threads

      break if @ending_flag
    end # end loop do
    ThreadsWait.all_waits(*@paginate_threads)
    ThreadsWait.all_waits(*@threads)

    @books
  end

  def isbn_to_13 isbn
    case isbn.length
    when 13
      return ISBN.thirteen isbn
    when 10
      return ISBN.thirteen isbn
    when 12
      return "#{isbn}#{isbn_checksum(isbn)}"
    when 9
      return ISBN.thirteen("#{isbn}#{isbn_checksum(isbn)}")
    end
  end

  def isbn_checksum(isbn)
    isbn.gsub!(/[^(\d|X)]/, '')
    c = 0
    if isbn.length <= 10
      10.downto(2) {|i| c += isbn[10-i].to_i * i}
      c %= 11
      c = 11 - c
      c ='X' if c == 10
      return c
    elsif isbn.length <= 13
      (1..11).step(2) {|i| c += isbn[i].to_i}
      c *= 3
      (0..11).step(2) {|i| c += isbn[i].to_i}
      c = (220-c) % 10
      return c
    end
  end
end

cc = HuatungBookCrawler.new
File.write('huatung_books.json', JSON.pretty_generate(cc.books))
