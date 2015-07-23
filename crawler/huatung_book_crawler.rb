require 'iconv'
require 'crawler_rocks'
require 'json'
require 'pry'

require 'book_toolkit'

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

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

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
            original_price = datas[2] && datas[2].text.gsub(/[^\d]/, '').to_i

            book[:url] = url
            book[:external_image_url] = external_image_url
            book[:name] = name
            book[:author] = author
            book[:original_price] = original_price
            book[:known_supplier] = 'huatung'

            # attr_datas = basic_data.xpath('a/jw').text.split("\n").map(&:strip).select{|s| !s.empty?}
            r = RestClient.get url
            doc = Nokogiri::HTML(r)

            attr_datas = doc.xpath('//table[@width="428"]/tr[2]/td/table/tr/td[2]/table/tr[position()>1]').map{|tr| tr.text.strip }.select{|tr| !tr.empty? && tr != " "}
            attr_datas.each {|data|
              key = ATTR_KEY[data.rpartition(/[:：]/)[0]]
              key && book[key] = data.rpartition(/[:：]/)[-1]
            }

            book[:invalid_isbn] = nil;
            begin
              book[:isbn] = BookToolkit.to_isbn13(book[:isbn])
            rescue Exception => e
              book[:invalid_isbn] = book[:isbn]
              book[:isbn] = nil
            end

            @after_each_proc.call(book: book) if @after_each_proc

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
end

# cc = HuatungBookCrawler.new
# File.write('huatung_books.json', JSON.pretty_generate(cc.books))
