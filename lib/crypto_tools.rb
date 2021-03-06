# coding: utf-8
require 'converters'
require 'block_crypto'
require 'stream_cipher'
require 'string_utils'
require 'securerandom'

class CryptoTools 
  def self.xor_str(str_a,str_b)
    if str_a.length != str_b.length
      raise "Length of input strings doesn't match!"
    end
    str_a.bytes.zip(str_b.bytes).map{ |x,y| x^y }.pack("C*")
  end
  def self.xor_key(str,key)
    key_str=""
    (Float(str.length)/key.length).ceil().times{ key_str+=key }
    xor_str(str,key_str.slice(0,str.length))
  end
  def self.hex_xor(hex_a,hex_b)
    Converters.str_to_hex(xor_str(Converters.hex_to_bytes(hex_a),
                                  Converters.hex_to_bytes(hex_b)))
  end
  def self.random_byte_string(nbytes)
    return SecureRandom.random_bytes(nbytes)
  end
  def self.freq_hist(test_str)
    hist = Hash.new(0)
    sani_str=test_str.scan(/[A-Za-z ]/).join.downcase
    total=sani_str.length
    sani_str.each_char {|c| 
      hist[c]+=1
    }
    hist.each_key{ |k|
      hist[k]/=Float(total)
    }
    return hist,total
  end
  def self.pearson_chi2(observed,expected)
    chi2=0
    expected.keys.each{ |c| 
      val=(observed[c]-expected[c])**2/expected[c]
      # puts sprintf "%s: \t Obs: %.3g \t Exp: %.3g \t QuadDiff: %.3g \t ChiTerm: %.3g ",c,observed[c],expected[c],(observed[c]-expected[c])**2,val
      chi2+=val
    }
    chi2
  end
  def self.build_hist(file_name)
    file=File.open(file_name)
    length=0
    hist=Hash.new(0)
    file.each_line do |l| 
      stripped=l.scan(/[[A-Za-z ]]/).join
      length+=stripped.length
      stripped.each_char do |c| 
        hist[c]+=1
      end
    end
    hist.each_key do |k| 
      hist[k]/=Float(length)
    end
  end
  def self.score_string(raw_string)
    english_freq={"a" => 0.0651738, "b" => 0.0124248, "c" => 0.0217339,
                  "d" => 0.0349835, "e" => 0.1041442, "f" => 0.0197881,
                  "g" => 0.0158610, "h" => 0.0492888, "i" => 0.0558094,
                  "j" => 0.0009033, "k" => 0.0050529, "l" => 0.0331490,
                  "m" => 0.0202124, "n" => 0.0564513, "o" => 0.0596302,
                  "p" => 0.0137645, "q" => 0.0008606, "r" => 0.0497563,
                  "s" => 0.0515760, "t" => 0.0729357, "u" => 0.0225134,
                  "v" => 0.0082903, "w" => 0.0171272, "x" => 0.0013692,
                  "y" => 0.0145984, "z" => 0.0007836, " " => 0.1918182}
    hist,total=freq_hist(raw_string)
    return pearson_chi2(hist,english_freq)
  end
  def self.break_xor(cipher_text,strict_ascii=true)
    key=''
    minscore=1e10
    for c in 0..255
      result = xor_key(cipher_text,c.chr.to_s)
      if strict_ascii and (result.scan(/[^[:print:]]/).length > 1 or
        Float(result.scan(/[^[A-Za-z ]]/).length)/result.length > 0.30)
        next
      end
      score=score_string(result)
      if score < minscore
        minscore=score
        key=c.chr.to_s
      end
    end
    return key,minscore
  end
  def self.undiffuse(y,c,b,dir=:left)
    # this is written for the 32 bit mersenne rng, inverts part of the
    # tempering function used in the mersenne twister
    # orig=0
    if dir!=:left and dir!=:right
      raise sprintf("Invalid direction: %s",dir.inspect)
    end
    mtrng=MersenneTwisterRng.new(1234)
    r=y
    ((32.0/c).ceil).times do 
      r = y ^ (dir==:left ? r << c : r >> c)&b 
    end
    return r
  end
  def self.untemper(y)
    y = self.undiffuse(y,18,0xffffffff,:right)
    y = self.undiffuse(y,15,0xefc60000,:left)
    y = self.undiffuse(y,7,0x9d2c5680,:left)
    y = self.undiffuse(y,11,0xffffffff,:right)
  end
  def self.hamming_distance(str1,str2)
    if str1.length != str2.length
      raise "Hamming distance undefined for strings if differing lengths"
    end
    dist=0
    str1.bytes.zip(str2.bytes).each{|x,y|
      dist+=(x^y).nbits
    }
    return dist
  end
  def self.detect_xor(strings)
    minscore=1e10
    validkey=""
    validline=""
    strings.each_line{ |l|
      cipher_text=Converters.hex_to_bytes(l.strip())
      key,score = CryptoTools.break_xor(cipher_text)
      if key!=""
        ascii_res=xor_key(cipher_text,key)
        if score < minscore
          minscore=score
          validkey=key
          validline=ascii_res
        end
      end
    }
    return validkey,validline
  end
  def self.find_keylen(cipher_byte_str)
    keylen=0
    minavg=1e10
    2.upto(40){ |kl|
      sample=[]
      25.times{ |i|
        sample+=[hamming_distance(cipher_byte_str.slice(i*kl,kl),
                                  cipher_byte_str.slice((i+1)*kl,kl))/Float(kl)]
      }
      average=0
      sample.each{ |val| average+=val }
      average/=sample.length
      if average < minavg
        minavg=average
        keylen=kl
      end
    }
    return keylen
  end
  def self.break_xor_key(cipher_text,keylen,strict_ascii=false)
    blocks=[]
    key_str=""
    (Float(cipher_text.length)/keylen).floor().times{ |i|
      blocks+=[cipher_text.slice(keylen*i,keylen).bytes]
    }
    blocks.transpose.each { |list|
      key,score=break_xor(list.pack("C*"),strict_ascii)
      key_str+=key
    }
    return key_str
  end
  def self.detect_aes_ecb(strings)
    strings.each_line{ |l|
      # break into 16 byte blocks
      # for each block check this block against all other blocks
      # if match, break and return string
      block_length=32
      cipher_text=l.strip()
      set = Hash.new(0)
      (Float(cipher_text.length)/block_length).ceil().times{ |i| 
        set[cipher_text.slice(block_length*i,block_length)]+=1
      }
      if set.values.inject{ |sum,x| sum + x}!=set.values.length
        # puts "ECB Detected!"
        return l
      end
    }
    return ""
  end
  def self.issue_reset_token
    mtrng=MersenneTwisterRng.new(Time.now.utc.to_i)
    return 256.times.map{mtrng.extract_number%256}.pack("C*")
  end
  def self.check_password_token(token)
    seed=Time.now.utc.to_i
    # try upto 5 minutes previous to see if this token came from a mersenne twister rng
    (5*60).times do |dt| 
      mtrng=MersenneTwisterRng.new(seed+dt)
      test_token=token.length.times.map{ mtrng.extract_number%256 }.pack("C*")
      if test_token == token
        return seed+dt
      end
    end
    return nil
  end
end
