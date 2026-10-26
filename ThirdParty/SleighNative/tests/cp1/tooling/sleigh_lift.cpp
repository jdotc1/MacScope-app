// CP1 offline test frontend. Uses the shipped Ghidra translation API directly.
// It is not the upstream lifting-bits tool and is not a native-XPC acceptance test.
#include "sleigh.hh"
#include "loadimage.hh"
#include "context.hh"
#include "xml.hh"
#include "marshal.hh"
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
using namespace ghidra;
namespace {
std::string jsonQuoted(const std::string &s) {
  std::ostringstream o; o << '"';
  for (unsigned char c:s) {
    switch(c) {case '"':o<<"\\\"";break;case '\\':o<<"\\\\";break;
      case '\n':o<<"\\n";break;case '\r':o<<"\\r";break;case '\t':o<<"\\t";break;
      default: if(c<32)o<<"\\u"<<std::hex<<std::setw(4)<<std::setfill('0')<<(unsigned)c<<std::dec;
               else o<<c;
    }
  } o << '"'; return o.str();
}
std::string xmlEscape(const std::string &s) {
  std::string out;
  for(char c:s) {if(c=='&')out+="&amp;";else if(c=='<')out+="&lt;";else out+=c;}
  return out;
}
struct Image final:LoadImage {
  uintb base=0x1000; std::vector<uint1> bytes;
  Image():LoadImage("cp1-instruction-bytes"){}
  void loadFill(uint1 *ptr,int4 size,const Address &addr) override {
    for(int4 i=0;i<size;++i) {
      const auto off=addr.getOffset()+i;
      ptr[i]=off>=base && off-base<bytes.size()? bytes[off-base]:0;
    }
  }
  std::string getArchType() const override{return "AARCH64";}
  void adjustVma(long) override{}
  void set(const std::string &hex) {
    if(hex.size()!=8)throw std::runtime_error("Expected exactly four instruction bytes as 8 hexadecimal characters");
    bytes.clear();
    for(std::size_t i=0;i<hex.size();i+=2) {
      const std::string s=hex.substr(i,2);std::size_t n=0;
      const auto value=std::stoul(s,&n,16);
      if(n!=2 || !std::isxdigit(s[0]) || !std::isxdigit(s[1]))throw std::runtime_error("Invalid hexadecimal bytes");
      bytes.push_back(static_cast<uint1>(value));
    }
  }
};
struct Asm final:AssemblyEmit {
  std::string mnemonic,body;
  void dump(const Address&,const std::string &m,const std::string &b)override{mnemonic=m;body=b;}
};
struct Code final:PcodeEmit {
  std::ostringstream text; const Sleigh &sleigh;
  explicit Code(const Sleigh &s):sleigh(s){}
  void vn(const VarnodeData &v) {text<<'('<<v.space->getName()<<",0x"<<std::hex<<v.offset<<std::dec<<','<<v.size<<')';}
  void dump(const Address&,OpCode opc,VarnodeData *out,VarnodeData *ins,int4 size)override{
    if(out){vn(*out);text<<" = ";}text<<get_opname(opc);
    for(int4 i=0;i<size;++i){text<<(i?", ":" ");
      VarnodeData v=ins[i];
      // Raw LOAD/STORE use a process-local AddrSpace pointer in operand zero.
      // Render its stable space index, and publish the index/name map in metadata.
      // This changes only serialization, not the emitted operation or its dataflow.
      if(i==0 && (opc==CPUI_LOAD || opc==CPUI_STORE)){
        for(int4 j=0;j<sleigh.numSpaces();++j){auto *sp=sleigh.getSpace(j);if(sp && v.offset==reinterpret_cast<std::uintptr_t>(sp)){v.offset=sp->getIndex();break;}}
      }
      vn(v);
    }text<<'\n';
  }
};
void defaults(const Element *el,ContextInternal &ctx) {
  if(el->getName()=="set"){
    const std::string n=el->getAttributeValue("name"),v=el->getAttributeValue("val");
    if(!n.empty()&&!v.empty())ctx.setVariableDefault(n,std::stoull(v,nullptr,0));
  }
  for(auto *child:el->getChildren())defaults(child,ctx);
}
void metadata(const Sleigh &s){
  std::cout<<"{\"frontend\":\"cp1-offline-api-v1\",\"bigEndian\":"<<(s.isBigEndian()?"true":"false")<<",\"registers\":{";
  std::map<VarnodeData,std::string> regs;s.getAllRegisters(regs);bool first=true;
  for(const auto &p:regs){if(!first)std::cout<<',';first=false;std::cout<<jsonQuoted(p.second)<<":["<<jsonQuoted(p.first.space->getName())<<','<<p.first.offset<<','<<p.first.size<<']';}
  std::cout<<"},\"userops\":{";std::vector<std::string> names;s.getUserOpNames(names);first=true;
  for(std::size_t i=0;i<names.size();++i){if(!first)std::cout<<',';first=false;std::cout<<jsonQuoted(std::to_string(i))<<':'<<jsonQuoted(names[i]);}
  std::cout<<"},\"spaces\":{";first=true;
  for(int4 i=0;i<s.numSpaces();++i){auto *sp=s.getSpace(i);if(!sp)continue;if(!first)std::cout<<',';first=false;std::cout<<jsonQuoted(std::to_string(sp->getIndex()))<<':'<<jsonQuoted(sp->getName());}
  std::cout<<"}}\n";
}
}
int main(int argc,char **argv){
  try{
    if(argc<3)throw std::runtime_error("usage: sleigh-lift pcode|disassemble|metadata|xml|batch SLA [BYTES] [-p TREE] [-s PSPEC]");
    const std::string mode=argv[1];std::filesystem::path file=argv[2];std::string hex,pspec,tree;
    int i=3;if(i<argc && argv[i][0]!='-')hex=argv[i++];
    for(;i<argc;++i){std::string flag=argv[i];if((flag!="-p"&&flag!="-s")||i+1==argc)throw std::runtime_error("Unknown or incomplete option");std::string value=argv[++i];if(flag=="-p")tree=value;else pspec=value;}
    if(!std::filesystem::exists(file) && !tree.empty())file=std::filesystem::path(tree)/"Ghidra/Processors/AARCH64/data/languages"/file;
    file=std::filesystem::absolute(file);
    AttributeId::initialize();ElementId::initialize();
    Image image;ContextInternal ctx;Sleigh s(&image,&ctx);DocumentStorage store;
    std::istringstream xml("<sleigh>"+xmlEscape(file.string())+"</sleigh>");
    store.registerTag(store.parseDocument(xml)->getRoot());s.initialize(store);
    if(!pspec.empty())defaults(store.openDocument(pspec)->getRoot(),ctx);
    if(mode=="metadata"){metadata(s);return 0;}
    if(mode=="xml"){XmlEncode enc(std::cout);s.encode(enc);return 0;}
    if(mode!="pcode" && mode!="disassemble" && mode!="batch")throw std::runtime_error("Unknown mode");
    do{
      if(mode=="batch" && !std::getline(std::cin,hex))break;
      if(!hex.empty()&&hex.back()=='\r')hex.pop_back();
      Asm a;Code c(s);std::string error;bool decoded=false;
      try{image.set(hex);Address addr(s.getDefaultCodeSpace(),image.base);s.printAssembly(a,addr);decoded=true;s.oneInstruction(c,addr);}
      catch(const LowlevelError &e){error=e.explain;}
      catch(const std::exception &e){error=e.what();}
      if(mode=="batch"){
        std::cout<<"{\"bytes\":"<<jsonQuoted(hex)<<",\"decoded\":"<<(decoded?"true":"false")<<",\"mnemonic\":"<<jsonQuoted(a.mnemonic)<<",\"body\":"<<jsonQuoted(a.body)<<",\"pcode\":"<<jsonQuoted(c.text.str())<<",\"error\":"<<jsonQuoted(error)<<"}\n";
        // A new address prevents Sleigh's parse cache from reusing the prior word.
        image.base+=16;
      }else{
        if(!error.empty())throw std::runtime_error(error);
        if(mode=="disassemble")std::cout<<a.mnemonic<<(a.body.empty()?"":" ")<<a.body<<'\n';
        else std::cout<<c.text.str();
        break;
      }
    }while(mode=="batch");
    return 0;
  }catch(const LowlevelError &e){std::cerr<<e.explain<<'\n';return 2;}
   catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 2;}
}
